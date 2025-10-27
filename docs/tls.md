HTTP(S) Client implementation.

Connections are opened in a thread-safe manner, but individual Requests are not.

TLS support may be disabled via std.options.http_disable_tls.
Fields

allocator: Allocator

Used for all client allocations. Must be thread-safe.

ca_bundle: if (disable_tls) void else std.crypto.Certificate.Bundle = if (disable_tls) {} else .{}

ca_bundle_mutex: std.Thread.Mutex = .{}

tls_buffer_size: if (disable_tls) u0 else usize = if (disable_tls) 0 else std.crypto.tls.Client.min_buffer_len

Used both for the reader and writer buffers.

ssl_key_log: ?*std.crypto.tls.Client.SslKeyLog = null

If non-null, ssl secrets are logged to a stream. Creating such a stream allows other processes with access to that stream to decrypt all traffic over connections created with this Client.

next_https_rescan_certs: bool = true

When this is true, the next time this client performs an HTTPS request, it will first rescan the system for root certificates.

connection_pool: ConnectionPool = .{}

The pool of connections that can be reused (and currently in use).

read_buffer_size: usize = 8192

Each Connection allocates this amount for the reader buffer.

If the entire HTTP header cannot fit in this amount of bytes, error.HttpHeadersOversize will be returned from Request.wait.

write_buffer_size: usize = 1024

Each Connection allocates this amount for the writer buffer.

http_proxy: ?*Proxy = null

If populated, all http traffic travels through this third party. This field cannot be modified while the client has active connections. Pointer to externally-owned memory.

https_proxy: ?*Proxy = null

If populated, all https traffic travels through this third party. This field cannot be modified while the client has active connections. Pointer to externally-owned memory.
Types

    ConnectTcpOptions
    Connection
    ConnectionPool
    FetchOptions
    FetchResult
    Protocol
    Proxy
    Request
    RequestOptions
    Response

Namespaces

    basic_authorization

Values
disable_tls
Functions

pub fn connect( client: *Client, host: []const u8, port: u16, protocol: Protocol, ) ConnectError!*Connection

    Connect to host:port using the specified protocol. This will reuse a connection if one is already open.
pub fn connectProxied( client: *Client, proxy: *Proxy, proxied_host: []const u8, proxied_port: u16, ) !*Connection

    Connect to proxied_host:proxied_port using the specified proxy with HTTP CONNECT. This will reuse a connection if one is already open.
pub fn connectTcp( client: *Client, host: []const u8, port: u16, protocol: Protocol, ) ConnectTcpError!*Connection

    Reuses a Connection if one matching host and port is already open.
pub fn connectTcpOptions(client: *Client, options: ConnectTcpOptions) ConnectTcpError!*Connection
pub fn connectUnix(client: *Client, path: []const u8) ConnectUnixError!*Connection

    Connect to path as a unix domain socket. This will reuse a connection if one is already open.
pub fn deinit(client: *Client) void

    Release all associated resources with the client.
pub fn fetch(client: *Client, options: FetchOptions) FetchError!FetchResult

    Perform a one-shot HTTP request with the provided options.
pub fn initDefaultProxies(client: *Client, arena: Allocator) !void

    Populates http_proxy and https_proxy via standard proxy environment variables. Asserts the client has no active connections. Uses arena for a few small allocations that must outlive the client, or at least until those fields are set to different values.
pub fn request( client: *Client, method: http.Method, uri: Uri, options: RequestOptions, ) RequestError!Request

    Open a connection to the host specified by uri and prepare to send a HTTP request.
pub fn sameParentDomain(parent_host: []const u8, child_host: []const u8) bool

Error Sets

    ConnectError
    ConnectTcpError
    ConnectUnixError
    FetchError
    RequestError
