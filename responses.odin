#+vet explicit-allocators
package natagent

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "core:io"
import "core:encoding/json"
import "base:runtime"

import "core:log"
import "core:crypto"
import "core:encoding/uuid"
import "core:bytes"
import "core:fmt"

import "http"
import "http/client"

Response_Create_Info :: struct {
    model:        string,
    input:        []Response_User_Message_Item_Param,
    instructions: string,
    store:        bool,
}

Response_Request :: struct {
    model:            string,
    input:            []Response_User_Message_Item_Param,
    instructions:     string,
    store:            bool,
    stream:           bool,
    prompt_cache_key: string,
}

Response_User_Message_Item_Param :: struct {
    id:      string `json:",omitempty"`, // optional
    type:    string `json:",omitempty"`,
    role:    string, // "user"
    content: string,
    status:  string `json:",omitempty"`, // optional
}

session_id_create :: proc(allocator: runtime.Allocator) -> string {
    context.random_generator  = crypto.random_generator()
    session_id               := uuid.generate_v4()
    return uuid.to_string_allocated(session_id, allocator)
}

SSE_Reader :: struct(BUFFER: int) {
    reader:     io.Reader,
    buffer:     [BUFFER]byte,
    buffer_len: int,
    event_read: bool,
}

SSE_Event :: struct {
    event: string,
    data:  string,
    id:    string,
    retry: int,
}

SSE_General_Error :: enum {
    None,
    Invalid_Utf8,
}

SSE_Error :: union #shared_nil {
    io.Error,
    SSE_General_Error,
}

test :: proc() {
    r: SSE_Reader(128)
    sse_next_event(&r, context.allocator)
}

sse_next_event :: proc(r: ^SSE_Reader($B), allocator: runtime.Allocator) -> SSE_Error {
    if r.buffer_len >= B {
        return .Buffer_Full
    }

    read         := io.read(r.reader, r.buffer[r.buffer_len:]) or_return
    r.buffer_len += read

    next_ch :: proc(r: ^SSE_Reader($B), i: int) -> (ch: rune, ch_len: int, err: SSE_Error) {
        ch, ch_len = utf8.decode_rune(r.buffer[r.buffer_len:])
        if ch == utf8.RUNE_EOF {
            err = .Invalid_Utf8
        }
        return
    }

    i := 0

    if !r.event_read {
        ch, ch_len := next_ch(r, i) or_return

        if ch == utf8.RUNE_BOM {
            i += ch_len
        }
    }

    event: SSE_Event
    current_field: string
    current_value: string

    event_end_field :: proc(event: ^SSE_Event, allocator: runtime.Allocator, current_field, current_value: string) {
        current_value := current_value

        if len(current_value) > 0 && current_value[0] == ' ' {
            current_value = current_value[1:]
        }

        switch current_field {
        case "event":
            event.event = strings.clone(current_value, allocator)
        case "data":
            event.data = strings.concatenate({ event.data, current_value, "\n" }, allocator)
        case "id":
            if !strings.contains(current_value, "\x00") {
                event.id = strings.clone(current_field, allocator)
            }
        case "retry":
            if len(current_value) < 1 {
                return
            }

            for r in current_value {
                switch r {
                case '0'..='9':
                case:
                    return
                }
            }

            value, ok := strconv.parse_int(current_value, 10)
            if !ok {
                return
            }
            event.retry = value
        }
    }

    line_found: bool

    loop: for i < r.buffer_len {
        ch, ch_len := next_ch(r, i) or_return

        switch ch {
        case '\r':
            i += ch_len

            if i >= r.buffer_len {
                line_found = true
                continue
            }

            peek_ch, peek_ch_len := next_ch(r, i+ch_len) or_return
            if peek_ch == '\n' {
                i += peek_ch_len
            }

            line_found = true
            continue
        case '\n':
            line_found = true
            continue
        }
        i += ch_len
    }

    return nil
}

response_create :: proc(auth: ^http.Headers, url: string, session_id: string, info: Response_Create_Info) {
    temp := TEMP_ALLOCATOR_GUARD()

    request := Response_Request {
        model            = info.model,
        input            = info.input,
        instructions     = info.instructions,
        store            = info.store,
        stream           = true,
        prompt_cache_key = session_id,
    }

    r: client.Request
    client.request_init(&r, .Post, temp)

    for key, value in auth._kv {
        http.headers_set(&r.headers, key, value)
    }
    http.headers_set(&r.headers, "session-id", session_id)
    http.headers_set_content_type_mime(&r.headers, .Json)

    log.debugf("headers: %v", r.headers)

    r_w := bytes.buffer_to_stream(&r.body)
    assert(json.marshal_to_writer(r_w, request, &{}) == nil)

    log.debugf("before request")
    response, err := client.request(&r, url, temp)
    fmt.println(response, err)
    log.debugf("after request")
    fmt.println(client.response_body(&response, allocator = temp))
    log.debugf("after body")
}
