#+vet explicit-allocators
package natagent

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
    id:      string, // optional
    type:    string,
    role:    string, // "user"
    content: string,
    status:  string, // optional
}

session_id_create :: proc(allocator: runtime.Allocator) -> string {
    context.random_generator  = crypto.random_generator()
    session_id               := uuid.generate_v4()
    return uuid.to_string_allocated(session_id, allocator)
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
    fmt.wprintf(r_w, `{{"model": "gpt-5.5", "input": [{{ "type": "message", "role": "user", "content": "Say hi" }], "instructions": "You are a proffessional Hi-Sayer", "store": false, "stream": true, "prompt_cache_key": %q}`, session_id)

    response, err := client.request(&r, url, temp)
    fmt.println(response, err)
    fmt.println(client.response_body(&response, allocator = temp))
}
