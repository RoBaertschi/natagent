#+vet explicit-allocators
package natagent

import "core:fmt"
import "base:runtime"

import "core:path/filepath"
import "core:mem/virtual"
import "core:log"
import "core:os"

import "http"

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

main :: proc() {
	context.logger = log.create_console_logger(allocator = context.allocator)

	temp := TEMP_ALLOCATOR_GUARD()

	token, ok := openai_codex_token_get(temp)
	assert(ok)

	h: http.Headers
	http.headers_init(&h, temp)
	http.headers_set(&h, "Authorization", fmt.aprintf("Bearer %s", token.access_token, allocator = temp))
	http.headers_set(&h, "ChatGPT-Account-Id", token.chatgpt_account_id)
	http.headers_set(&h, "originator", "natagent")
	http.headers_set(&h, "User-Agent", "natagent/0.1")

	session_id := session_id_create(temp)
	response_create(&h, "https://chatgpt.com/backend-api/codex/responses", session_id, {
		model        = "gpt-5.5",
		input        = {{ role = "user", content = "Say Hi" }},
		instructions = "You are a professional Hi sayer.",
		store        = false,
	})
}


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

