#+vet explicit-allocators
package natagent

import "core:path/filepath"
import "core:bytes"
import "core:encoding/json"
import "core:strings"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:fmt"
import "core:time"
import "core:nbio"
import "core:log"
import "core:sync"
import "core:net"
import "core:os"
import "core:math/rand"
import "core:crypto"
import "http"
import "http/client"

config_home :: proc(allocator: runtime.Allocator) -> string {
    config_home := os.get_env("XDG_CONFIG_HOME", allocator)
    if config_home == "" {
        temp := TEMP_ALLOCATOR_GUARD(allocator)

        home := os.user_home_dir(temp) or_else "~"
        return filepath.join({ home, ".config" }, allocator) or_else "~/.config"
    }
    return config_home
}

data_home :: proc(allocator: runtime.Allocator) -> string {
    data_home := os.get_env("XDG_DATA_HOME", allocator)
    if data_home == "" {
        temp := TEMP_ALLOCATOR_GUARD(allocator)

        home := os.user_home_dir(temp) or_else "~"
        return filepath.join({ home, ".local", "share" }, allocator) or_else "~/.local/share"
    }
    return data_home
}

run :: proc(args: ..string) -> (state: os.Process_State, err: os.Error) {
    allocator := TEMP_ALLOCATOR_GUARD()

    desc := os.Process_Desc{
        command = args,
    }

    stdout, stderr: []byte
    state, stdout, stderr = os.process_exec(desc, allocator) or_return

    return
}

Openai_Codex_Login_State :: struct {
    mu:    sync.Mutex,

    server:   http.Server,
    code_buf: [256]u8,
    code:     string,
    state:    [43]byte,
    timeout:  ^nbio.Operation,
    success:  bool,
}

_openai_codex_login_state: Openai_Codex_Login_State

url_save_random :: proc(data: []byte) {
    allocator := TEMP_ALLOCATOR_GUARD()
    state_possible := make([dynamic]u8, allocator)

    for r in u8('a')..='z' {
        append(&state_possible, r)
    }

    for r in u8('A')..='Z' {
        append(&state_possible, r)
    }

    for r in u8('0')..='9' {
        append(&state_possible, r)
    }

    append(&state_possible, '_', '-', '~', '.')

    gen := crypto.random_generator()


    for &b in data {
        b = rand.choice(state_possible[:], gen)
    }
}

Openai_Codex_Token :: struct {
    id_token:           string,
    access_token:       string,
    refresh_token:      string,
    expires_in:         time.Time,
    chatgpt_account_id: string,
}

CONFIG_SUBDIR :: "natagent"
CONFIG_AUTH   :: "auth.json"

config_auth_path :: proc(allocator: runtime.Allocator) -> string {
    temp := TEMP_ALLOCATOR_GUARD(allocator)

    config        := config_home(temp)
    config_subdir := filepath.join({ config, CONFIG_SUBDIR }, temp) or_else "~/.config/" + CONFIG_SUBDIR

    os.mkdir_all(config_subdir)

    config_auth := filepath.join({ config_subdir, CONFIG_AUTH }, allocator) or_else "~/.config/" + CONFIG_SUBDIR + "/" + CONFIG_AUTH

    return config_auth
}

openai_codex_token_save :: proc(t: Openai_Codex_Token) {
    temp := TEMP_ALLOCATOR_GUARD()

    config_auth := config_auth_path(temp)
    f, os_err := os.create(config_auth)
    if os_err != nil {
        log.errorf("could not create auth config: %v", os_err)
        return
    }
    defer os.close(f)

    f_stream := os.to_stream(f)
    json_err := json.marshal_to_writer(f_stream, t, &{ pretty = true, use_spaces = true, spec = .JSON })
    if json_err != nil {
        log.errorf("could not serialize json into %q: %v", config_auth, json_err)
        return
    }
}

openai_codex_token_load :: proc(allocator: runtime.Allocator) -> (t: Openai_Codex_Token) {
    temp := TEMP_ALLOCATOR_GUARD(allocator)

    config_auth := config_auth_path(temp)
    data, os_err := os.read_entire_file(config_auth, temp)

    switch os_err {
    case .Not_Exist:
        return
    case:
        log.errorf("could not read auth config %q: %v", config_auth, os_err)
        return
    case nil:
    }

    json_err := json.unmarshal(data, &t, allocator = allocator)
    if json_err != nil {
        log.errorf("could not deserialize auth config %q: %v", config_auth, os_err)
        return
    }
    return
}

OPENAI_CODEX_CLIENT_ID :: "app_EMoamEEZ73f0CkXaXp7hrann"
OPENAI_CODEX_ISSUER    :: "https://auth.openai.com"
OPENAI_CODEX_PORT      :: 1455
OPENAI_CODEX_CALLBACK  :: "http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"

openai_codex_request_oauth_token :: proc(
    allocator: runtime.Allocator,
    format: string,
    args: ..any
) -> (token: Openai_Codex_Token, ok: bool) {

    temp := TEMP_ALLOCATOR_GUARD(allocator)

    r: client.Request
    client.request_init(&r, .Post, temp)

    r_w := bytes.buffer_to_stream(&r.body)

    r_body := fmt.wprintf(r_w,
        format,
        ..args,
    )

    http.headers_set(&r.headers, "Content-Type", "application/x-www-form-urlencoded")

    url := OPENAI_CODEX_ISSUER + "/oauth/token"
    log.debugf("requesting %q", url)

    res, res_err := client.request(&r, url, temp)
    if res_err != nil {
        log.errorf("could not request token: %v", res_err)
        return
    }

    body, _, body_err := client.response_body(&res, allocator = temp)
    if body_err != nil {
        log.errorf("could not read body of token request: %v", body_err)
        return
    }

    body_text: string

    switch b in body {
    case client.Body_Plain:
        body_text = b
    case client.Body_Url_Encoded:
        log.errorf("unexpected url encoded body from token request")
        return
    case client.Body_Error:
        log.errorf("could not read body of token request: %v", b)
        return
    }

    Token :: struct {
        id_token:      string,
        access_token:  string,
        refresh_token: string,
        expires_in:    time.Duration,
    }


    t: Token
    unmarshal_err := json.unmarshal(transmute([]byte)body_text, &t, allocator =  temp)
    if unmarshal_err != nil {
        log.errorf("could not parse body of token request: %v", unmarshal_err)
        return
    }

    t.expires_in *= time.Second

    extract_chatgpt_account_id :: proc(jwt: string, allocator: runtime.Allocator) -> (id: string, ok: bool) {
        jwt := jwt
        temp := TEMP_ALLOCATOR_GUARD(allocator)

        // first part
        _ = strings.split_iterator(&jwt, ".") or_return
        second := strings.split_iterator(&jwt, ".") or_return
        result, err := base64.decode(second, base64.DEC_URL_TABLE, allocator = temp)
        if err != nil {
            log.debugf("could not decode base64url in jwt token: %v", err)
            return
        }

        m: json.Object
        json_err := json.unmarshal(result, &m, allocator = temp)
        if json_err != nil {
            log.debugf("could not unmarshal jwt token: %v", json_err)
            return
        }

        account_id := m["chatgpt_account_id"]
        if id, ok = account_id.(json.String); ok {
            id = strings.clone(id, allocator)
            return
        }

        url_path := m["https://api.openai.com/auth"]
        if url_path_object, url_path_object_ok := url_path.(json.Object); url_path_object_ok {
            url_account_id := url_path_object["chatgpt_account_id"]
            if id, ok = url_account_id.(json.String); ok {
                id = strings.clone(id, allocator)
                return
            }
        }

        orgs := m["organizations"]
        if orgs_array, orgs_array_ok := orgs.(json.Array); orgs_array_ok {
            if len(orgs_array) > 0 {
                org := orgs_array[0]
                if org_object, org_object_ok := org.(json.Object); org_object_ok {
                    org_id := org_object["id"]
                    if id, ok = org_id.(json.String); ok {
                        id = strings.clone(id, allocator)
                        return
                    }
                }
            }
        }

        return
    }

    token = {
        id_token           = strings.clone(t.id_token, allocator),
        access_token       = strings.clone(t.access_token, allocator),
        refresh_token      = strings.clone(t.refresh_token, allocator),
        chatgpt_account_id = extract_chatgpt_account_id(t.id_token, allocator)     or_else (
                              extract_chatgpt_account_id(t.access_token, allocator) or_else
                              ""),
        expires_in         = time.time_add(time.now(), t.expires_in - time.Minute * 2),
    }
    ok = true
    return
}

openai_codex_login :: proc(allocator: runtime.Allocator) -> (token: Openai_Codex_Token, ok: bool) {
    log.info("not logged in, logging in")

    ensure(sync.try_lock(&_openai_codex_login_state.mu), "INVALID STATE: openai codex login state called while already locked")
    defer sync.unlock(&_openai_codex_login_state.mu)

    temp := TEMP_ALLOCATOR_GUARD(allocator)

    _openai_codex_login_state.server = {}
    _openai_codex_login_state.success = false

    code_verifier: [64]byte
    url_save_random(code_verifier[:])

    code_verifier_hash: [32]byte

    hash_ctx: sha2.Context_256
    sha2.init_256(&hash_ctx)
    sha2.update(&hash_ctx, code_verifier[:])
    sha2.final(&hash_ctx, code_verifier_hash[:])

    code_challange := base64.encode(code_verifier_hash[:], base64.ENC_URL_TABLE, temp)

    first_padding := strings.index(code_challange, "=")
    code_challange = code_challange[:first_padding if first_padding != -1 else len(code_challange)]

    url_save_random(_openai_codex_login_state.state[:])

    url := fmt.aprintf(OPENAI_CODEX_ISSUER + "/oauth/authorize?response_type=code&client_id=" + OPENAI_CODEX_CLIENT_ID + "&redirect_uri=%s&scope=openid+profile+email+offline_access&code_challenge=%s&code_challenge_method=S256&id_token_add_organizations=true&codex_cli_simplified_flow=true&state=%s&originator=natagent", OPENAI_CODEX_CALLBACK, code_challange, _openai_codex_login_state.state, allocator = temp)
    run("xdg-open", url)
    log.debugf("opening %s", url)

    http.server_shutdown_on_interrupt(&_openai_codex_login_state.server)

    router: http.Router
    http.router_init(&router, temp)
    defer http.router_destroy(&router)

    err := nbio.acquire_thread_event_loop()
    if err != nil {
        log.errorf("could not optain thread event loop: %v", err)
        return
    }
    defer nbio.release_thread_event_loop()

    _openai_codex_login_state.timeout = nbio.timeout(time.Minute * 5, proc(_op: ^nbio.Operation) {
        if _openai_codex_login_state.success {
            return
        }

        log.errorf("login timeout of 5 minutes exeeded, stopping server")
        http.server_shutdown(&_openai_codex_login_state.server)
    })

    http.route_get(&router, "/auth/callback", http.handler(proc(req: ^http.Request, res: ^http.Response) {
        if _openai_codex_login_state.timeout == nil {
            http.respond_plain(res, "500 Internal Server Error", .Bad_Request)
            log.errorf("callback called after timeout")
            return
        }

        state, state_found := http.query_get(req.url, "state")
        code,  code_found  := http.query_get(req.url, "code")

        validate_state :: proc(state: string) -> bool {
            if len(state) != len(_openai_codex_login_state.state) {
                return false
            }

            if state != transmute(string)_openai_codex_login_state.state[:] {
                return false
            }

            return true
        }

        if !state_found || !code_found || !validate_state(state) {
            http.respond_plain(res, "400 Bad Request", .Bad_Request)
            return
        }

        if len(code) > len(_openai_codex_login_state.code_buf) {
            http.respond_plain(res, "500 Internal Server Error", .Bad_Request)
            log.errorf("received code larger than %d characters, which is not supported", len(_openai_codex_login_state.code_buf))
            return
        }

        copy(_openai_codex_login_state.code_buf[:], code)
        _openai_codex_login_state.code = transmute(string)_openai_codex_login_state.code_buf[:len(code)]

        _openai_codex_login_state.success = true
        http.respond_plain(res, "Login successfull")
        http.server_shutdown(&_openai_codex_login_state.server)

        // as we do not do any 
        nbio.remove(_openai_codex_login_state.timeout)
    }))

    http.listen_and_serve(
        &_openai_codex_login_state.server,
        http.router_handler(&router),
        { address = net.IP4_Any, port = OPENAI_CODEX_PORT },
        {
            auto_expect_continue = true,
            limit_headers        = 8000,
            limit_request_line   = 8000,
            redirect_head_to_get = true,
            thread_count         = 1,
        },
    )

    if !_openai_codex_login_state.success {
        return
    }

    return openai_codex_request_oauth_token(
        allocator,
        "grant_type=authorization_code&code=%s&redirect_uri=%s&client_id=%s&code_verifier=%s",
        _openai_codex_login_state.code,
        OPENAI_CODEX_CALLBACK,
        OPENAI_CODEX_CLIENT_ID,
        code_verifier,
    )
}

openai_codex_token_refresh :: proc(token: Openai_Codex_Token, allocator: runtime.Allocator) -> (Openai_Codex_Token, bool) {
    return openai_codex_request_oauth_token(
        allocator,
        "grant_type=refresh_token&refresh_token=%s&client_id=%s",
        token.refresh_token,
        OPENAI_CODEX_CLIENT_ID,
    )
}

openai_codex_token_get :: proc(allocator: runtime.Allocator) -> (token: Openai_Codex_Token, ok: bool) {
    temp  := TEMP_ALLOCATOR_GUARD(allocator)
    token  = openai_codex_token_load(temp)

    if time.time_to_unix_nano(
        time.time_add(token.expires_in, -time.Minute * 5)) < time.time_to_unix_nano(time.now()) {

        if token.refresh_token == "" {
            token, ok = openai_codex_login(allocator)
            if !ok {
                log.errorf("could not log into codex")
                return
            }

            openai_codex_token_save(token)
        } else {
            log.info("token about to expire, refreshing...")
            token, ok = openai_codex_token_refresh(token, allocator)
            if !ok {
                log.error("could not refresh token")
            } else {
                openai_codex_token_save(token)
            }
            return
        }
    }

    token = {
        id_token           = strings.clone(token.id_token, allocator),
        refresh_token      = strings.clone(token.refresh_token, allocator),
        access_token       = strings.clone(token.access_token, allocator),
        chatgpt_account_id = strings.clone(token.chatgpt_account_id, allocator),
        expires_in         = token.expires_in,
    }

    ok = true
    return
}

main :: proc() {
    context.logger = log.create_console_logger(allocator = context.allocator)

    temp := TEMP_ALLOCATOR_GUARD()

    token, ok := openai_codex_token_get(temp)
    assert(ok)
}


import "core:mem/virtual"
import "base:runtime"

@(private="file")
MAX_TEMP_ARENA_COUNT :: 2
@(private="file")
MAX_TEMP_ARENA_COLLISIONS :: MAX_TEMP_ARENA_COUNT - 1
@(private="file", thread_local)
global_default_temp_allocator_arenas: [MAX_TEMP_ARENA_COUNT]virtual.Arena

@(fini, private)
temp_allocator_fini :: proc "contextless" () {
    context = runtime.default_context()

    for &arena in global_default_temp_allocator_arenas {
        virtual.arena_destroy(&arena)
    }
    global_default_temp_allocator_arenas = {}
}

Temp_Allocator :: struct {
    using arena: ^virtual.Arena,
    using allocator: runtime.Allocator,
    tmp: virtual.Arena_Temp,
    loc: runtime.Source_Code_Location,
}

TEMP_ALLOCATOR_GUARD_END :: proc(temp: Temp_Allocator) {
    virtual.arena_temp_end(temp.tmp, temp.loc)
}

@(deferred_out=TEMP_ALLOCATOR_GUARD_END)
TEMP_ALLOCATOR_GUARD :: #force_inline proc(collisions: ..runtime.Allocator, loc := #caller_location) -> Temp_Allocator {
    assert(len(collisions) <= MAX_TEMP_ARENA_COLLISIONS, "Maximum collision count exceeded. MAX_TEMP_ARENA_COUNT must be increased!")
    good_arena: ^virtual.Arena
    for i in 0..<MAX_TEMP_ARENA_COUNT {
        good_arena = &global_default_temp_allocator_arenas[i]
        for c in collisions {
            if good_arena == c.data {
                good_arena = nil
            }
        }
        if good_arena != nil {
            break
        }
    }
    assert(good_arena != nil)
    tmp := virtual.arena_temp_begin(good_arena, loc)
    return { good_arena, virtual.arena_allocator(good_arena), tmp, loc }
}

temp_allocator_begin :: virtual.arena_temp_begin
temp_allocator_end :: virtual.arena_temp_end
@(deferred_out=_temp_allocator_end)
temp_allocator_scope :: proc(tmp: Temp_Allocator) -> (virtual.Arena_Temp) {
    return temp_allocator_begin(tmp.arena)
}
@(private="file")
_temp_allocator_end :: proc(tmp: virtual.Arena_Temp) {
    temp_allocator_end(tmp)
}

@(init, private)
init_thread_local_cleaner :: proc "contextless" () {
    runtime.add_thread_local_cleaner(temp_allocator_fini)
}

