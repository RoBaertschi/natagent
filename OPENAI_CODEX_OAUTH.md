# OpenAI Codex OAuth and API Notes

This documents the OpenAI Codex OAuth flow and API usage observed in `opencode`.
This is not the normal public OpenAI Platform API-key flow. It uses ChatGPT/Codex
OAuth credentials and calls ChatGPT's Codex backend.

The observed client values are:

```text
issuer:    https://auth.openai.com
client_id: app_EMoamEEZ73f0CkXaXp7hrann
callback:  http://localhost:1455/auth/callback
codex api: https://chatgpt.com/backend-api/codex/responses
```

## Browser Sign-In

Use an OAuth authorization-code flow with PKCE.

Before opening the browser, create:

```text
code_verifier  = random URL-safe secret
code_challenge = base64url(sha256(code_verifier))
state          = random URL-safe secret
```

Start a local HTTP listener on:

```text
http://localhost:1455/auth/callback
```

Open this URL in the user's browser:

```http
GET /oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&scope=openid+profile+email+offline_access&code_challenge=CODE_CHALLENGE&code_challenge_method=S256&id_token_add_organizations=true&codex_cli_simplified_flow=true&state=STATE&originator=opencode HTTP/1.1
Host: auth.openai.com
```

After sign-in, the browser redirects to your local callback:

```http
GET /auth/callback?code=AUTHORIZATION_CODE&state=STATE HTTP/1.1
Host: localhost:1455
```

Validate that the callback `state` exactly matches the `state` you generated.
Reject the login if it does not match.

Exchange the authorization code for tokens:

```http
POST /oauth/token HTTP/1.1
Host: auth.openai.com
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code&code=AUTHORIZATION_CODE&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&client_id=app_EMoamEEZ73f0CkXaXp7hrann&code_verifier=CODE_VERIFIER
```

Expected token response shape:

```json
{
  "id_token": "ID_TOKEN",
  "access_token": "ACCESS_TOKEN",
  "refresh_token": "REFRESH_TOKEN",
  "expires_in": 3600
}
```

Store:

```text
access_token
refresh_token
expires_at = now + expires_in
account_id, if available
```

The account id can be extracted from the JWT claims in `id_token` first, then
`access_token` as a fallback. Known claim locations:

```text
chatgpt_account_id
https://api.openai.com/auth.chatgpt_account_id
organizations[0].id
```

## Local OAuth Callback Server

The browser sign-in flow needs a small temporary HTTP server. It does not need
sessions, cookies, static files, TLS, or general routing.

Required listener:

```text
localhost:1455
```

Required route:

```http
GET /auth/callback?code=AUTHORIZATION_CODE&state=STATE HTTP/1.1
Host: localhost:1455
```

Required callback handling:

```text
read query parameter code
read query parameter state
read optional query parameter error
read optional query parameter error_description
if error exists, fail login
if code is missing, fail login
if state does not match the generated state, fail login
if valid, exchange code for tokens
return a simple success HTML response to the browser
stop the local server after success or failure
timeout pending login after a few minutes
```

Optional cancel route:

```http
GET /cancel HTTP/1.1
Host: localhost:1455
```

If implemented, `/cancel` should reject the pending login and return a simple
plain-text or HTML response.

## Headless Sign-In

Use this when a browser callback to localhost is inconvenient.

Start device authorization:

```http
POST /api/accounts/deviceauth/usercode HTTP/1.1
Host: auth.openai.com
Content-Type: application/json
User-Agent: opencode/VERSION

{
  "client_id": "app_EMoamEEZ73f0CkXaXp7hrann"
}
```

Expected response shape:

```json
{
  "device_auth_id": "DEVICE_AUTH_ID",
  "user_code": "USER_CODE",
  "interval": "5"
}
```

Show the user:

```text
https://auth.openai.com/codex/device
USER_CODE
```

Poll for authorization:

```http
POST /api/accounts/deviceauth/token HTTP/1.1
Host: auth.openai.com
Content-Type: application/json
User-Agent: opencode/VERSION

{
  "device_auth_id": "DEVICE_AUTH_ID",
  "user_code": "USER_CODE"
}
```

While waiting, `403` or `404` means keep polling. Wait at least the returned
`interval`; opencode also adds a 3 second safety margin.

When approved, expected response shape:

```json
{
  "authorization_code": "AUTHORIZATION_CODE",
  "code_verifier": "CODE_VERIFIER"
}
```

Exchange the authorization code:

```http
POST /oauth/token HTTP/1.1
Host: auth.openai.com
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code&code=AUTHORIZATION_CODE&redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback&client_id=app_EMoamEEZ73f0CkXaXp7hrann&code_verifier=CODE_VERIFIER
```

Store the returned tokens the same way as browser sign-in.

## Refresh Tokens

Refresh before `access_token` expires:

```http
POST /oauth/token HTTP/1.1
Host: auth.openai.com
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token&refresh_token=REFRESH_TOKEN&client_id=app_EMoamEEZ73f0CkXaXp7hrann
```

Expected response shape:

```json
{
  "id_token": "ID_TOKEN",
  "access_token": "NEW_ACCESS_TOKEN",
  "refresh_token": "NEW_REFRESH_TOKEN",
  "expires_in": 3600
}
```

Replace the stored refresh token when the response includes a new one.

## Codex Responses Endpoint

Use the OAuth access token against:

```text
https://chatgpt.com/backend-api/codex/responses
```

Basic request:

```http
POST /backend-api/codex/responses HTTP/1.1
Host: chatgpt.com
Authorization: Bearer ACCESS_TOKEN
ChatGPT-Account-Id: ACCOUNT_ID
Content-Type: application/json
originator: opencode
User-Agent: opencode/VERSION
session-id: SESSION_ID

{
  "model": "gpt-5.5",
  "input": "Say hello.",
  "store": false
}
```

Useful body options observed in opencode recordings:

```json
{
  "model": "gpt-5.5",
  "input": [
    {
      "role": "user",
      "content": [
        {
          "type": "input_text",
          "text": "What is the weather in Paris?"
        }
      ]
    }
  ],
  "instructions": "Answer using tools when appropriate.",
  "tools": [
    {
      "type": "function",
      "name": "get_weather",
      "description": "Get the current weather for a city.",
      "parameters": {
        "type": "object",
        "properties": {
          "city": { "type": "string" }
        },
        "required": ["city"],
        "additionalProperties": false
      }
    }
  ],
  "store": false,
  "stream": true,
  "prompt_cache_key": "stable-cache-key",
  "include": ["reasoning.encrypted_content"],
  "reasoning": {
    "effort": "medium",
    "summary": "auto"
  },
  "text": {
    "verbosity": "low"
  }
}
```

Common options:

```text
model                 model id to run
input                 user input, prior output items, and tool results
instructions          developer/system-style instructions
tools                 function tools or supported built-in tools
store                 whether to store the response; opencode uses false
stream                whether to return server-sent events
prompt_cache_key      stable key for prompt caching
include               extra fields to include, such as reasoning.encrypted_content
reasoning.effort      reasoning budget, such as low, medium, high
reasoning.summary     reasoning summary mode, such as auto
text.verbosity        output verbosity, such as low, medium, high
previous_response_id  continue from a previous response when supported
```

For streamed HTTP responses, expect server-sent events:

```text
event: response.created
data: {...}

event: response.output_text.delta
data: {...}

event: response.completed
data: {...}
```

## Tool Continuation

When the model returns a function call, send a follow-up request with prior
items plus a `function_call_output`.

```http
POST /backend-api/codex/responses HTTP/1.1
Host: chatgpt.com
Authorization: Bearer ACCESS_TOKEN
ChatGPT-Account-Id: ACCOUNT_ID
Content-Type: application/json
originator: opencode
User-Agent: opencode/VERSION
session-id: SESSION_ID

{
  "model": "gpt-5.5",
  "input": [
    {
      "role": "user",
      "content": [
        {
          "type": "input_text",
          "text": "What is the weather in Paris?"
        }
      ]
    },
    {
      "type": "function_call",
      "call_id": "CALL_ID",
      "name": "get_weather",
      "arguments": "{\"city\":\"Paris\"}"
    },
    {
      "type": "function_call_output",
      "call_id": "CALL_ID",
      "output": "{\"temperature\":22,\"condition\":\"sunny\"}"
    }
  ],
  "tools": [
    {
      "type": "function",
      "name": "get_weather",
      "description": "Get the current weather for a city.",
      "parameters": {
        "type": "object",
        "properties": {
          "city": { "type": "string" }
        },
        "required": ["city"],
        "additionalProperties": false
      }
    }
  ],
  "store": false,
  "stream": true
}
```

If you requested `include: ["reasoning.encrypted_content"]`, preserve returned
reasoning items with `encrypted_content` when continuing the same reasoning
thread.

## WebSocket Responses

opencode can stream Responses over WebSocket for session-affine streamed
requests. The WebSocket URL is the HTTP Codex endpoint with `https` replaced by
`wss`:

```http
GET /backend-api/codex/responses HTTP/1.1
Host: chatgpt.com
Authorization: Bearer ACCESS_TOKEN
ChatGPT-Account-Id: ACCOUNT_ID
openai-beta: responses_websockets=2026-02-06
originator: opencode
User-Agent: opencode/VERSION
session-id: SESSION_ID
Connection: Upgrade
Upgrade: websocket
```

Send a response creation message:

```json
{
  "type": "response.create",
  "model": "gpt-5.5",
  "input": "Say hello.",
  "store": false,
  "stream": true
}
```

Use HTTP fallback when:

```text
the request is not POST /responses
stream is not true
there is no session-id or x-session-affinity header
the session socket is already busy
the session socket has repeatedly failed
the request is for title generation
```

## Chat Completions Compatibility

opencode removes any existing `Authorization` header, adds the Codex OAuth
headers, and rewrites requests whose path includes either:

```text
/v1/responses
/chat/completions
```

to:

```text
https://chatgpt.com/backend-api/codex/responses
```

In practice, prefer the Responses-shaped body above for this backend.

## Model Access

When authenticated through this OAuth path, opencode filters OpenAI models to a
Codex-oriented set. Observed explicit allowed models:

```text
gpt-5.5
gpt-5.3-codex-spark
gpt-5.4
gpt-5.4-mini
```

It also allows models matching `gpt-X.Y` when `X.Y > 5.4`.

## Required Headers

For Codex backend calls:

```text
Authorization: Bearer ACCESS_TOKEN
ChatGPT-Account-Id: ACCOUNT_ID
originator: opencode
User-Agent: opencode/VERSION
session-id: SESSION_ID
Content-Type: application/json
```

`ChatGPT-Account-Id` is included when available from token claims. `session-id`
is used for conversation/session affinity and WebSocket reuse.

## Error Handling

For browser auth:

```text
callback error or error_description -> fail login
missing callback code -> fail login
state mismatch -> fail login
token exchange non-2xx -> fail login
```

For device auth:

```text
403 or 404 while polling -> keep waiting
other non-2xx while polling -> fail
token exchange non-2xx -> fail
```

For API calls:

```text
expired access token -> refresh first, then retry request
refresh non-2xx -> require sign-in again
WebSocket setup/stream failure -> fall back to HTTP after retry budget
```

## Security Notes

Treat all tokens like passwords. Do not log them, commit them, or expose them to
client-side code. Store `refresh_token` in a secret store or encrypted local
credential storage when possible.

PKCE protects the authorization code, but it does not protect stored tokens.
Refresh tokens can mint new access tokens until revoked or expired.

This flow is based on observed opencode behavior and can change without public
API compatibility guarantees.
