// minihttp.goose - the shape of a heap-less HTTP service. Sockets come from
// a tiny C shim (net.c, net.build); everything above them is Goose.
import std;

extern fn gs_listen(port: i32, backlog: i32) -> i64;
extern fn gs_accept(fd: i64) -> i64;
extern fn gs_read(fd: i64, buf: u8&, cap: i64) -> i64;
extern fn gs_write(fd: i64, buf: const u8&, len: i64) -> i64;
extern fn gs_close(fd: i64) -> i64;

struct Reply { status: u8[..16], body: u8[..64] }

fn route(method: u8[:], path: u8[:]) -> Reply {
    if method == "GET" && path == "/healthz" { return Reply { "200 OK", "ok" }; }
    if method == "GET" && starts_with(path, "/api/items/") { return Reply { "200 OK", "{\"item\":1}" }; }
    return Reply { "404 Not Found", "no such route" };
}

// One connection: request bytes, parsed fields and the response all live in
// this call's frame and are gone when it returns.
fn serve(fd: i64) {
    var req: u8[..8192] = [0; 8192];
    let n = gs_read(fd, req[0], req.len);
    if n <= 0 { return; }
    let text = req[..n];
    let line_end = find(text, "\r\n");
    if line_end < 0 { return; }
    let line = text[..line_end];
    let sp1 = find(line, " ");
    if sp1 < 0 { return; }
    let sp2 = find(line[sp1 + 1..], " ");
    if sp2 < 0 { return; }
    let method = line[..sp1];
    let path = line[sp1 + 1..sp1 + 1 + sp2];
    let rep = route(method, path);

    var out: u8[>..] = [];
    out.append("HTTP/1.1 "); out.append(rep.status); out.append("\r\n");
    out.append("Content-Length: "); format(out, rep.body.len); out.append("\r\n");
    out.append("Connection: close\r\n\r\n");
    out.append(rep.body);
    var sent = 0;
    while sent < out.len {
        let w = gs_write(fd, out[sent], out.len - sent);
        if w <= 0 { return; }
        sent += w;
    }
}

fn main() {
    let lfd = gs_listen(18080, 128);
    if lfd < 0 { abort("cannot listen on 127.0.0.1:18080"); }
    print("listening on 127.0.0.1:18080");
    loop {
        let fd = gs_accept(lfd);
        if fd < 0 { continue; }
        serve(fd);
        gs_close(fd);
    }
}
