#+vet explicit-allocators
package natagent

import "core:strings"
import "base:runtime"

import "core:io"
import "core:fmt"
import "core:log"
import "core:bytes"
import "core:crypto"
import "core:encoding/json"
import "core:encoding/uuid"

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
	body, _, body_err := client.response_body(&response, allocator = temp)
	log.debugf("after body: %v", body_err)

	plain := body.(client.Body_Plain)

	reader: SSE_Reader
	body_reader: strings.Reader
	strings.reader_init(&body_reader, plain)

	sse_init(&reader, make([]byte, runtime.Kilobyte * 32, allocator = temp), strings.reader_to_stream(&body_reader))

	event: SSE_Event

	dispatched: bool
	sse_err: SSE_Error
	for dispatched, sse_err = sse_progress(&reader, &event, temp); !(sse_err == nil || sse_err == .EOF); dispatched, sse_err = sse_progress(&reader, &event, temp) {
		if dispatched {
			Event :: struct {
				type:            string,
				sequence_number: Maybe(int),
				response:        json.Object,
			}

			ev: Event
			json_err := json.unmarshal_string(event.data, &ev, allocator = temp)
			if json_err != nil {
				log.errorf("could not unmarshal streaming response: %v", json_err)
				continue
			}

			fmt.assertf(ev.type == event.event, "%q != %q: %v", ev.type, event.event, event.data)
			switch ev.type {
			case "response.completed":
				log.info(event.event, ev, "\n\n")
			case "response.failed":
				log.info(event.event,  ev, "\n\n")
			case "response.incomplete":
				log.info(event.event, ev, "\n\n")
			case "error":
				log.info(event.event, ev, "\n\n")
			}

			// log.infof("event(%v, data=%v)", event.event, strings.trim_right_space(event.data))

			event = {}
		}

		if sse_err == .EOF {
			break
		}
	}

	// log.infof("%v\nsse_err: %v", plain, sse_err)
}
