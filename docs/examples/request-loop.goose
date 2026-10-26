
// request-loop.goose - request-scoped work: every byte a request needs is
// freed when its scope ends, so the process needs the peak of one request,
// not a total.
//
//   pixi run goose docs/examples/request-loop.goose < requests.txt
import std;
import json;
import os;

struct Route { method: u8[..8], prefix: u8[..24], status: i32 }
struct Counters { requests: i64, bytes: i64, not_found: i64 }

fn route_index(routes: Route[:], method: u8[:], path: u8[:]) -> i64 {
    for i in routes.len {
        if routes[i].method == method && starts_with(path, routes[i].prefix) {
            return i;
        }
    }
    return -1;
}

// One request. Its line, fields and response all live in this call's scope.
fn handle(routes: Route[:], line: u8[:], out: u8[>..]&) -> i64 {
    let fields = split(line, ' ');
    if fields.len != 3 { return -1; }
    let size, size_ok = parse_int(fields[2]);
    let idx = route_index(routes, fields[0], fields[1]);
    let status = if idx < 0 { 404 } else { routes[idx].status };
    json::format_string(out, fields[1]);
    out.push(':');
    format(out, status);
    if !size_ok { out.push('?'); }
    return if idx < 0 { -1 } else { size };
}

fn main() {
    let routes: Route[3] = [
        Route { "GET", "/healthz", 200 },
        Route { "GET", "/api/v1/items/", 200 },
        Route { "POST", "/api/v1/orders", 201 },
    ];

    var counters = Counters { requests: 0, bytes: 0, not_found: 0 };
    var line: u8[>..] = [];            // reused; capacity is the longest line
    var response: u8[>..] = [];        // reused; capacity is the largest response
    while read_line(line) {
        response.clear();
        let size = handle(routes, line, response);
        counters.requests++;
        if size < 0 { counters.not_found++; } else { counters.bytes += size; }
        line.clear();
    }
    print("requests=", counters.requests, " bytes=", counters.bytes, " not_found=", counters.not_found);
}
