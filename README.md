# zigserver

This project is for recreational purposes to demonstrate building a REST API server in Zig. It features a simple in-memory data store for managing "Person" records.

Later it should use either SQLite or Postgres for persistent storage.

Also will try to optimize for performance and low memory usage. Data Oriented Design (DOD) principles will be applied where possible.

SIMD optimizations may be explored for data processing tasks.

Already supports HTTP/1.1 with keep-alive connections and multi-threaded request handling and Response Stream chunking.
