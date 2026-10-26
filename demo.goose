// demo.goose - a small program that exercises the Goose compiler and runtime.
//
// Run in-process with TinyCC:  goose demo.goose
// Build a native binary:       goose build demo.goose && ./demo

struct Summary {
    count: i64,
    largest: i64,
}

// Trial division is enough for the small range below.
fn is_prime(n: i64) -> bool {
    if n < 2 { return false; }
    var d = 2;
    while d * d <= n {
        if n % d == 0 { return false; }
        d++;
    }
    return true;
}

recursive fn fib(n: i64) -> i64 {
    if n < 2 { return n; }
    return fib(n - 1) + fib(n - 2);
}

fn total(xs: i64[:]) -> i64 {
    var t = 0;
    for x in xs { t += x; }
    return t;
}

fn summarize(xs: i64[:]) -> Summary {
    var s = Summary { count: 0, largest: 0 };
    for x in xs {
        s.count++;
        if x > s.largest { s.largest = x; }
    }
    return s;
}

fn main() {
    print("Goose demo: primes and Fibonacci");

    var primes: i64[>..] = [];
    for n in 2..30 {
        if is_prime(n) { primes.push(n); }
    }
    print("primes below 30: ", primes);

    let s = summarize(primes);
    print("count=", s.count, " largest=", s.largest);

    var fibs: i64[>..] = [];
    for i in 10 { fibs.push(fib(i)); }
    print("fib(0..9): ", fibs);
    print("sum(fib)=", total(fibs));
}
