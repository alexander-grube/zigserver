# REST API - Refactored Architecture

This project demonstrates a well-structured REST API in Zig following best practices for modularity, maintainability, and thread safety.

## Architecture Overview

The codebase follows a modular architecture with clear separation of concerns:

```
src/
├── main.zig          # Clean entry point - bootstrap and server startup
├── server.zig        # Server implementation with multi-threaded connection handling
├── http.zig          # HTTP protocol abstractions (Request, Response, Status, Method)
├── router.zig        # Request routing and handler registration
└── root.zig          # Business logic (Person, PersonStore) - the "playground" module
```

## Key Design Principles

### 1. **Separation of Concerns**
Each module has a single, well-defined responsibility:
- `main.zig`: Application bootstrap
- `server.zig`: Network and connection management
- `http.zig`: HTTP protocol handling
- `router.zig`: Request routing and dispatching
- `root.zig`: Business logic and data models

### 2. **HTTP Abstraction Layer**
The `http.zig` module provides clean abstractions:
- **Request**: Parsed HTTP request with headers, method, path, and body
- **Response**: Type-safe response builder with status codes
- **Method**: Enumerated HTTP methods
- **Status**: Type-safe status codes with descriptive text

### 3. **Router Pattern**
The `router.zig` implements a clean routing system:
- Pattern-based route matching (e.g., `/people/:id`)
- Handler function registration
- Automatic parameter extraction
- Centralized error handling

### 4. **Thread Safety**
The `PersonStore` uses `std.Thread.Mutex` for thread-safe operations:
- All mutating operations are protected by mutex
- Read operations are also synchronized for consistency
- Multi-threaded server can safely handle concurrent requests

### 5. **HTTP/1.1 Keep-Alive**
Proper keep-alive implementation:
- 30-second idle timeout
- Connection pooling support
- Graceful connection closing
- Poll-based non-blocking I/O

## Code Organization Best Practices

### Clean Entry Point (`main.zig`)
```zig
pub fn main() !void {
    // 1. Setup allocator
    // 2. Initialize data store
    // 3. Create server
    // 4. Start listening
}
```

### Modular Server (`server.zig`)
- `Server` struct encapsulates server state
- `ConnectionContext` for thread-local data
- Detached threads for concurrent handling
- Clean error handling and logging

### Type-Safe HTTP (`http.zig`)
- Enums for methods and status codes
- Structured request parsing
- Response builders for common content types
- Automatic header management

### Flexible Router (`router.zig`)
- Route registration with pattern matching
- Handler function type definition
- Extractable path parameters
- CRUD operation handlers

### Business Logic (`root.zig`)
- `Person` struct with proper formatting
- `PersonStore` with CRUD operations
- Mutex-protected shared state
- JSON parsing utilities

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/people` | List all people |
| GET | `/people/:id` | Get person by ID |
| POST | `/people` | Create new person |
| PUT | `/people/:id` | Update person by ID |
| DELETE | `/people/:id` | Delete person by ID |
| OPTIONS | `*` | CORS preflight |

## Thread Safety Model

The server uses a multi-threaded model:
1. Main thread accepts connections
2. Each connection spawns a detached worker thread
3. Worker threads access shared `PersonStore` via mutex
4. Each request is independent and non-blocking

## Build and Run

```bash
# Build
zig build

# Run
./zig-out/bin/playground

# Test
curl http://127.0.0.1:8080/people
curl -X POST http://127.0.0.1:8080/people \
  -H "Content-Type: application/json" \
  -d '{"name":"John Doe","age":30,"job":"Engineer"}'
```

## Benefits of This Architecture

1. **Maintainability**: Each module has a clear purpose
2. **Testability**: Components can be tested in isolation
3. **Scalability**: Thread-safe design supports concurrent requests
4. **Extensibility**: Easy to add new routes and handlers
5. **Type Safety**: Strong typing prevents common HTTP errors
6. **Performance**: Non-blocking I/O with connection pooling

## Zig Best Practices Applied

- ✅ Module system with clear boundaries
- ✅ Error unions for proper error handling
- ✅ Defer for resource cleanup
- ✅ Thread safety with Mutex
- ✅ Allocator-aware design
- ✅ Comptime for zero-cost abstractions
- ✅ `std.ArrayList` with `.empty` initialization (Zig 0.15.2)
- ✅ Proper memory management with allocator passing
