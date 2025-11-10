# Person REST API

A REST API server built in Zig for managing Person records with name, age, and job fields.

## Building and Running

```bash
# Build the project
zig build

# Run the server
zig build run
# OR
./zig-out/bin/playground
```

The server will start on `http://127.0.0.1:8080`

## API Endpoints

### GET /people
List all people in the system.

**Example:**
```bash
curl http://127.0.0.1:8080/people
```

**Response:**
```json
[
  {"name":"Alice Smith","age":28,"job":"Software Engineer"},
  {"name":"Bob Johnson","age":35,"job":"Product Manager"}
]
```

### GET /people/:id
Get a specific person by their index (0-based).

**Example:**
```bash
curl http://127.0.0.1:8080/people/0
```

**Response:**
```json
{"name":"Alice Smith","age":28,"job":"Software Engineer"}
```

### POST /people
Create a new person record.

**Example:**
```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"name":"Charlie Brown","age":42,"job":"Designer"}' \
  http://127.0.0.1:8080/people
```

**Response:**
```json
{"name":"Charlie Brown","age":42,"job":"Designer"}
```

### PUT /people/:id
Update an existing person by their index.

**Example:**
```bash
curl -X PUT \
  -H "Content-Type: application/json" \
  -d '{"name":"Robert Johnson","age":36,"job":"Senior Product Manager"}' \
  http://127.0.0.1:8080/people/1
```

**Response:**
```json
{"name":"Robert Johnson","age":36,"job":"Senior Product Manager"}
```

### DELETE /people/:id
Delete a person by their index.

**Example:**
```bash
curl -X DELETE http://127.0.0.1:8080/people/1
```

**Response:**
```text
Deleted successfully
```

## Person Structure

```zig
pub const Person = struct {
    name: []const u8,
    age: u32,
    job: []const u8,
};
```

## Implementation Details

- **In-Memory Storage**: Uses `PersonStore` with an `ArrayList` to store person records
- **Memory Management**: Properly allocates and frees memory for string fields
- **HTTP/1.1 Keep-Alive**: Persistent connections with 30-second idle timeout
  - Connections stay open for multiple requests
  - Automatically closes after 30 seconds of inactivity
  - Supports up to 100 requests per connection
  - Respects `Connection: close` header from clients
- **HTTP Server**: TCP-based HTTP server with manual request parsing and polling
- **JSON Parsing**: Uses `std.json.parseFromSlice` for parsing incoming JSON data
- **Sample Data**: Server starts with two sample person records

## HTTP Keep-Alive

The server implements HTTP/1.1 persistent connections:

- **Connection Reuse**: Multiple requests can be sent on the same TCP connection
- **Timeout**: Connections automatically close after 30 seconds of inactivity
- **Headers**: Responses include `Connection: keep-alive` and `Keep-Alive: timeout=30, max=100`
- **Client Control**: Clients can send `Connection: close` to immediately close after response

**Example with keep-alive:**
```bash
# Using curl with persistent connection
curl --keepalive-time 5 http://127.0.0.1:8080/people

# Force connection close
curl -H "Connection: close" http://127.0.0.1:8080/people
```

## Error Handling

- Returns `400 Bad Request` for invalid JSON or malformed IDs
- Returns `404 Not Found` for non-existent person IDs or undefined endpoints
- Returns `200 OK` for successful GET, PUT, DELETE operations
- Returns `201 Created` for successful POST operations

## Testing

Run the unit tests with:
```bash
zig build test
```
