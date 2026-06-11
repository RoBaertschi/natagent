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
    reader:        io.Reader,
    buffer:        [BUFFER]byte,
    buffer_len:    int,
}

SSE_Event :: struct {
    event: string,
    data:  string,
    id:    string,
    retry: int,
}

SSE_General_Error :: enum {
    None,
    Newline_Not_Found,
    Invalid_Utf8,
}

SSE_Error :: union #shared_nil {
    io.Error,
    SSE_General_Error,
}

test :: proc() {
    r: SSE_Reader(128)
    _, _ = _sse_consume_next_line(&r, context.allocator)
    sse_progress(&r, nil, context.allocator)
    _sse_update_buffer(&r)
}

// https://html.spec.whatwg.org/multipage/server-sent-events.html

_sse_buffer_is_full :: proc(r: ^SSE_Reader($B)) -> bool {
    assert(r != nil)

    return B - r.buffer_len <= 0
}

/*
Reads the next line in the SSE_Reader.

Inputs:
- r: The reader to read from, this function only uses the buffer
- i: Where to start looking for the line end in the buffer
- allocator: The allocator used to allocate the returned string, probably a temporary arena

NOTE: i must point to the start of an UTF-8 code point or the function will fail

Returns:
- line: A cloned string containing the full line or "" if none found or empty
- idx: The index after the end of the line (after \n, \r, \r\n), is r.buffer_len if none found
- err: Indicates invalid stream or not enough data in buffer
*/
@require_results
_sse_next_line :: proc(r: ^SSE_Reader($B), i: int, allocator: runtime.Allocator) -> (line: string, line_end: int, err: SSE_General_Error) {
    assert(r != nil)
    assert(0 <= i && i < r.buffer_len)
    assert(allocator.procedure != nil)

    // HACK(robin): if the \r of a \r\n is the last character of the buffer,
    //              but a \n is not yet there, this logic would be incorrect.
    //              possible solution is to just say, that a \r with an missing character
    //              after it is not a valid new line

    defer {
        assert(0 <= line_end && line_end <= r.buffer_len)
        assert(i <= line_end)
    }

    line_end = i

    for line_end < r.buffer_len {
        ch, ch_len := utf8.decode_rune(r.buffer[line_end:r.buffer_len])
        if ch == utf8.RUNE_ERROR {
            err = .Invalid_Utf8
            return
        }
        line_end += ch_len

        switch ch {
        case '\r':
            if r.buffer_len <= line_end {
                // We could not ensure, that there is no \n following
                err = .Newline_Not_Found
                return
            }

            peek_ch, peek_ch_len := utf8.decode_rune(r.buffer[line_end:r.buffer_len])
            if peek_ch == utf8.RUNE_ERROR {
                err = .Invalid_Utf8
                return
            }

            if peek_ch == '\n' {
                line_end += ch_len
            }

            fallthrough
        case '\n':
            line = strings.clone_from_bytes(r.buffer[i:line_end], allocator)
            return
        }
    }

    err = .Newline_Not_Found
    return
}

/*
Get the next line in the buffer and then remove said line from the buffer

Inputs:
- r: A valid reader
- allocator: Allocator used to allocate line, needs to be valid

WARN: only allocates on if a line was actually found (check err)

Returns:
- line: Found line, or "" if not found(also for empty lines)
- err: A general SSE error (`Invalid_Utf8` or `Newline_Not_Found`)
*/
_sse_consume_next_line :: proc(r: ^SSE_Reader($B), allocator: runtime.Allocator) -> (line: string, err: SSE_General_Error) {
    assert(r != nil)
    assert(allocator.procedure != nil)

    defer {
        if err != nil {
            assert(line == "")
        }
    }

    line_end: int
    line, line_end = _sse_next_line(r, 0, allocator) or_return
    new_buffer_len := r.buffer_len - line_end
    assert(copy(r.buffer[:], r.buffer[line_end:r.buffer_len]) == new_buffer_len)
    r.buffer_len = new_buffer_len
    return
}

/*
Read from `r.reader` and fill the buffer as far as possible

Inputs:
- r: A valid reader

NOTE: An error does not indicate that the buffer was not updated,
      some errors might be temporary and some data was still read

Returns:
- err: an error indicating the success of the read
- read: the amount of new bytes read, can also be `> 0` when `err != nil`
*/
_sse_update_buffer :: proc(r: ^SSE_Reader($B)) -> (read: int, err: io.Error) {
    assert(r != nil)

    defer {
        assert(0 <= read)
        assert(r.buffer_len <= B)
    }

    if _sse_buffer_is_full(r) {
        return
    }

    read, err = io.read(r.reader, r.buffer[r.buffer_len:])
    if 0 < read {
        r.buffer_len += read
    }

    return
}

/*
Progresses the current `SSE_Reader` with the provided WIP `event`.

Inputs:
- r: a valid `SSE_Reader`
- event: a in-out pointer to a WIP event
- allocator: allocator to allocate the fields inside event with

**Usage**
- the passed in event is used to stream the current event into
- true is returned when said event is dispatched and ready to be used
- said event must be reset manually by the user
- it is recommended to copy the contents of the event out of the event itself and reset it for reuse

WARN: The passed in events field are allocated with `allocator`, as long as you intend to
      use this function, those fields should not be freed, ideally you wait until an event
      is dispatched, copy the fields out into a more permanent allocator and then reset `allocator`

NOTE: `event.data` will always end with an `\n`, if you don't want that, strip it off

Returns:
- `bool` is true, if the event is dispatched (finished) and ready to use
- `SSE_Error` unrecoverable error, either an `io.Error` or `SSE_General_Error.Invalid_Utf8`
*/
sse_progress :: proc(r: ^SSE_Reader($B), event: ^SSE_Event, allocator: runtime.Allocator) -> (bool, SSE_Error) {
    assert(r != nil)
    assert(event != nil)
    assert(allocator.procedure != nil)

    temp := TEMP_ALLOCATOR_GUARD(allocator)

    // We assume that this is non-blocking, but that is currently not true
    read, read_err := _sse_update_buffer(r)
    if read_err != .EOF {
        return false, read_err
    }

    for {
        line, err := _sse_consume_next_line(r, temp)
        switch err {
        case .Newline_Not_Found:
            // We can not do anything now
            if read_err == .EOF {
                return false, .Unexpected_EOF
            }

            // This is only an error, if the buffer is already full
            if _sse_buffer_is_full(r) {
                return false, .Buffer_Full
            }

            // nothing to process
            assert(read_err == nil)
            return false, nil
        case .Invalid_Utf8:
            return false, err
        case .None: // continue, found line
        }

        if line == "" {
            return true, read_err
        }

        field, value: string

        colon_search := ":"
        colon := strings.index(line, colon_search)
        switch {
        case colon < 0:
            field = line
        case colon == 0:
            continue
        case:
            field = line[:colon]
            value = line[colon+len(colon_search):]
        }

        if len(value) > 0 && value[0] == ' ' {
            value = value[1:]
        }

        sw: switch field {
        case "event":
            event.event = strings.clone(value, allocator)
        case "data":
            event.data = strings.concatenate({ event.data, value, "\n" }, allocator = allocator)
        case "id":
            if strings.index(value, "\x00") < 0 {
                event.id = strings.clone(value, allocator)
            }
        case "retry":
            for r in value {
                if '0' <= r && r <= '9' {
                    continue
                }

                break sw
            }

            event.retry = strconv.parse_int(value, 10) or_break sw
        }
    }
}

// sse_next_event :: proc(r: ^SSE_Reader($B), allocator: runtime.Allocator) -> SSE_Error {
//     if r.buffer_len >= B {
//         return .Buffer_Full
//     }
//
//     read         := io.read(r.reader, r.buffer[r.buffer_len:]) or_return
//     r.buffer_len += read
//
//     next_ch :: proc(r: ^SSE_Reader($B), i: int) -> (ch: rune, ch_len: int, err: SSE_Error) {
//         ch, ch_len = utf8.decode_rune(r.buffer[r.buffer_len:])
//         if ch == utf8.RUNE_EOF {
//             err = .Invalid_Utf8
//         }
//         return
//     }
//
//     i := 0
//
//     if !r.event_read {
//         ch, ch_len := next_ch(r, i) or_return
//
//         if ch == utf8.RUNE_BOM {
//             i += ch_len
//         }
//     }
//
//     event: SSE_Event
//     current_field: string
//     current_value: string
//
//     event_end_field :: proc(event: ^SSE_Event, allocator: runtime.Allocator, current_field, current_value: string) {
//         current_value := current_value
//
//         if len(current_value) > 0 && current_value[0] == ' ' {
//             current_value = current_value[1:]
//         }
//
//         switch current_field {
//         case "event":
//             event.event = strings.clone(current_value, allocator)
//         case "data":
//             event.data = strings.concatenate({ event.data, current_value, "\n" }, allocator)
//         case "id":
//             if !strings.contains(current_value, "\x00") {
//                 event.id = strings.clone(current_field, allocator)
//             }
//         case "retry":
//             if len(current_value) < 1 {
//                 return
//             }
//
//             for r in current_value {
//                 switch r {
//                 case '0'..='9':
//                 case:
//                     return
//                 }
//             }
//
//             value, ok := strconv.parse_int(current_value, 10)
//             if !ok {
//                 return
//             }
//             event.retry = value
//         }
//     }
//
//     line_found: bool
//
//     loop: for i < r.buffer_len {
//         ch, ch_len := next_ch(r, i) or_return
//
//         switch ch {
//         case '\r':
//             i += ch_len
//
//             if i >= r.buffer_len {
//                 line_found = true
//                 continue
//             }
//
//             peek_ch, peek_ch_len := next_ch(r, i+ch_len) or_return
//             if peek_ch == '\n' {
//                 i += peek_ch_len
//             }
//
//             line_found = true
//             continue
//         case '\n':
//             line_found = true
//             continue
//         }
//         i += ch_len
//     }
//
//     return nil
// }

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
