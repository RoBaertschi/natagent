#+vet explicit-allocators
package natagent

import "base:runtime"

import "core:io"
import "core:strings"
import "core:strconv"
import "core:unicode/utf8"

SSE_Reader :: struct {
    reader:        io.Reader,
    buffer:        []byte,
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
    r: SSE_Reader
    _, _ = _sse_consume_next_line(&r, context.allocator)
    sse_progress(&r, nil, context.allocator)
    _sse_update_buffer(&r)
}

// https://html.spec.whatwg.org/multipage/server-sent-events.html

_sse_buffer_is_full :: proc(r: ^SSE_Reader) -> bool {
    assert(r != nil)

    return len(r.buffer) - r.buffer_len <= 0
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
_sse_next_line :: proc(r: ^SSE_Reader, i: int, allocator: runtime.Allocator) -> (line: string, line_end: int, err: SSE_General_Error) {
    assert(r != nil)
    assert(0 <= i)
    assert(i < r.buffer_len)
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

        clone_offset := 0

        switch ch {
        case '\r':
            clone_offset -= 1

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
                line_end += peek_ch_len
                clone_offset -= 1
            }

            line = strings.clone_from_bytes(r.buffer[i:line_end+clone_offset], allocator)
            return
        case '\n':
            clone_offset -= 1
            line = strings.clone_from_bytes(r.buffer[i:line_end+clone_offset], allocator)
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
_sse_consume_next_line :: proc(r: ^SSE_Reader, allocator: runtime.Allocator) -> (line: string, err: SSE_General_Error) {
    assert(r != nil)
    assert(allocator.procedure != nil)

    defer {
        if err != nil {
            assert(line == "")
        }
    }

    if r.buffer_len <= 0 {
        return "", .Newline_Not_Found
    }

    line_end: int
    line, line_end  = _sse_next_line(r, 0, allocator) or_return
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
_sse_update_buffer :: proc(r: ^SSE_Reader) -> (read: int, err: io.Error) {
    assert(r != nil)

    defer {
        assert(0 <= read)
        assert(r.buffer_len <= len(r.buffer))
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
sse_progress :: proc(r: ^SSE_Reader, event: ^SSE_Event, allocator: runtime.Allocator) -> (bool, SSE_Error) {
    assert(r != nil)
    assert(event != nil)
    assert(allocator.procedure != nil)

    temp := TEMP_ALLOCATOR_GUARD(allocator)

    // We assume that this is non-blocking, but that is currently not true
    read, read_err := _sse_update_buffer(r)
    if read_err != .EOF && read_err != nil {
        return false, read_err
    }

    for {
        line, err := _sse_consume_next_line(r, temp)
        switch err {
        case .Newline_Not_Found:
            // We can not do anything now
            if read_err == .EOF {
                return false, .EOF
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
            return true, r.buffer_len <= 0 ? .EOF : nil
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

/*
Initialize a `SSE_Reader` using the provided reader.

Inputs:
- r: A valid `SSE_Reader`
- reader: A reader from where to fetch the events

NOTE: This function skips the BOM if available

Returns:
- A `SSE_Error` for updating the buffer the first time
*/
sse_init :: proc(r: ^SSE_Reader, buf: []byte, reader: io.Reader) -> SSE_Error {
    assert(r != nil)
    assert(len(buf) > 0)

    r^ = { reader = reader, buffer = buf }
    read, err := _sse_update_buffer(r)
    if !(err == .EOF && read > 0) && err != nil {
        return err
    }

    ch, ch_len := utf8.decode_rune(r.buffer[:r.buffer_len])
    if ch == utf8.RUNE_ERROR {
        return .Invalid_Utf8
    }

    if ch == utf8.RUNE_BOM {
        new_buffer_len := r.buffer_len - ch_len
        assert(copy(r.buffer[:], r.buffer[ch_len:r.buffer_len]) == new_buffer_len)
        r.buffer_len = new_buffer_len
    }

    return nil
}

// Tests

import "core:testing"

@(private="file")
SSE_Test :: struct {
    r:      strings.Reader,
    stream: io.Reader,
    sse_r:  SSE_Reader,
}

@(private="file", deferred_in=sse_test_fini)
sse_test_init :: proc(sse_test: ^SSE_Test, buffer_size: int, s: string) -> SSE_Error {
    strings.reader_init(&sse_test.r, s)
    sse_test.stream = strings.reader_to_stream(&sse_test.r)
    return sse_init(&sse_test.sse_r, make([]byte, buffer_size, context.allocator), sse_test.stream)
}

@(private="file")
sse_test_fini :: proc(sse_test: ^SSE_Test, buffer_size: int, s: string) {
    delete(sse_test.sse_r.buffer, context.allocator)
}

@test
test_init_bom :: proc(t: ^testing.T) {
    test: SSE_Test
    testing.expect(t, sse_test_init(&test, 20, "\ufeff") == nil)
    testing.expect(t, test.sse_r.buffer_len == 0)
}

@test
test_init_no_bom :: proc(t: ^testing.T) {
    test: SSE_Test
    testing.expect(t, sse_test_init(&test, 20, "hi") == nil)
    testing.expect(t, test.sse_r.buffer_len == 2)
}

@test
test_init_invalid_utf8 :: proc(t: ^testing.T) {
    test: SSE_Test
    testing.expect_value(t, sse_test_init(&test, 20, "\xff \xff"), SSE_General_Error.Invalid_Utf8)
    testing.expect_value(t, test.sse_r.buffer_len, 3)
}

@test
test_read_event :: proc(t: ^testing.T) {
    test: SSE_Test
    testing.expect_value(t, sse_test_init(&test, 32, "event: hi\r\n\r\n"), nil)
    testing.expect_value(t, test.sse_r.buffer_len, 13)
    temp := TEMP_ALLOCATOR_GUARD()
    event: SSE_Event
    dispatched, err := sse_progress(&test.sse_r, &event, temp)
    testing.expect_value(t, dispatched, true)
    testing.expect_value(t, err, io.Error.EOF)
    testing.expect_value(t, event.data, "")
    testing.expect_value(t, event.id, "")
    testing.expect_value(t, event.retry, 0)
    testing.expect_value(t, event.event, "hi")
}

@test
test_read_event2 :: proc(t: ^testing.T) {
    test: SSE_Test
    testing.expect_value(t, sse_test_init(&test, 32, "event: hi\r\n\r\nevent: hi2\r\n\r\n"), nil)
    testing.expect_value(t, test.sse_r.buffer_len, 27)
    temp := TEMP_ALLOCATOR_GUARD()
    event: SSE_Event
    dispatched, err := sse_progress(&test.sse_r, &event, temp)
    testing.expect_value(t, dispatched, true)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, event.data, "")
    testing.expect_value(t, event.id, "")
    testing.expect_value(t, event.retry, 0)
    testing.expect_value(t, event.event, "hi")

    dispatched, err = sse_progress(&test.sse_r, &event, temp)
    testing.expect_value(t, dispatched, true)
    testing.expect_value(t, err, io.Error.EOF)
    testing.expect_value(t, event.data, "")
    testing.expect_value(t, event.id, "")
    testing.expect_value(t, event.retry, 0)
    testing.expect_value(t, event.event, "hi2")
}

@test
test_read_event_missing_empty :: proc(t: ^testing.T) {
    test: SSE_Test
    testing.expect_value(t, sse_test_init(&test, 32, "event: hi\r\n"), nil)
    testing.expect_value(t, test.sse_r.buffer_len, 11)
    temp := TEMP_ALLOCATOR_GUARD()
    event: SSE_Event
    dispatched, err := sse_progress(&test.sse_r, &event, temp)
    testing.expect_value(t, dispatched, false)
    testing.expect_value(t, err, io.Error.EOF)
}

@test
test_read_event_early_eof :: proc(t: ^testing.T) {
    test: SSE_Test
    testing.expect_value(t, sse_test_init(&test, 32, "event:"), nil)
    testing.expect_value(t, test.sse_r.buffer_len, 6)
    temp := TEMP_ALLOCATOR_GUARD()
    event: SSE_Event
    dispatched, err := sse_progress(&test.sse_r, &event, temp)
    testing.expect_value(t, dispatched, false)
    testing.expect_value(t, err, io.Error.EOF)
}

@test
test_read_event_full_buffer :: proc(t: ^testing.T) {
    test: SSE_Test
    testing.expect_value(t, sse_test_init(&test, 32, "event: hi, how are, hope you are doing well\n\r\n\r"), nil)
    testing.expect_value(t, test.sse_r.buffer_len, 32)
    temp := TEMP_ALLOCATOR_GUARD()
    event: SSE_Event
    dispatched, err := sse_progress(&test.sse_r, &event, temp)
    testing.expect_value(t, dispatched, false)
    testing.expect_value(t, err, io.Error.Buffer_Full)
}

@test
test_read_event_across_buffer :: proc(t: ^testing.T) {
    test: SSE_Test
    testing.expect_value(
        t,
        sse_test_init(
            &test,
            32,
            "event: hi\r\ndata: yolo how are you, i am\r\n\r\n",
        ),
        nil
    )
    testing.expect_value(t, test.sse_r.buffer_len, 32)
    temp := TEMP_ALLOCATOR_GUARD()
    event: SSE_Event
    dispatched, err := sse_progress(&test.sse_r, &event, temp)
    testing.expect_value(t, dispatched, false)
    testing.expect_value(t, err, nil)
    dispatched, err = sse_progress(&test.sse_r, &event, temp)
    testing.expect_value(t, dispatched, true)
    testing.expect_value(t, err, io.Error.EOF)
    testing.expect_value(t, event.data, "yolo how are you, i am\n")
    testing.expect_value(t, event.id, "")
    testing.expect_value(t, event.retry, 0)
    testing.expect_value(t, event.event, "hi")
}

@test
test_read_event_across_buffer_new_lines :: proc(t: ^testing.T) {
    test: SSE_Test
    testing.expect_value(
        t,
        sse_test_init(
            &test,
            32,
            "event: hi\rdata: yolo how are you, i am\r\r\n",
        ),
        nil
    )
    testing.expect_value(t, test.sse_r.buffer_len, 32)
    temp := TEMP_ALLOCATOR_GUARD()
    event: SSE_Event
    dispatched, err := sse_progress(&test.sse_r, &event, temp)
    testing.expect_value(t, dispatched, false)
    testing.expect_value(t, err, nil)
    dispatched, err = sse_progress(&test.sse_r, &event, temp)
    testing.expect_value(t, dispatched, true)
    testing.expect_value(t, err, io.Error.EOF)
    testing.expect_value(t, event.data, "yolo how are you, i am\n")
    testing.expect_value(t, event.id, "")
    testing.expect_value(t, event.retry, 0)
    testing.expect_value(t, event.event, "hi")
}
