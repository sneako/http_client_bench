use bytes::Bytes;
use chrono::Utc;
use hdrhistogram::Histogram;
use http::Method;
use http_body_util::{BodyExt, Full};
use hyper::Request;
use hyper_rustls::{HttpsConnector, HttpsConnectorBuilder};
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::Client as HyperClient;
use hyper_util::rt::TokioExecutor;
use reqwest::Client;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, Error as RustlsError, SignatureScheme};
use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::task::JoinSet;

#[derive(Clone)]
struct Scenario {
    name: String,
    method: Method,
    path: String,
    headers: Vec<(String, String)>,
    body: Option<Bytes>,
    #[allow(dead_code)]
    response_bytes: usize,
}

struct Config {
    server_host: String,
    server_port: u16,
    scheme: String,
    http_version: String,
    duration_s: u64,
    warmup_s: u64,
    concurrency: usize,
    request_timeout_ms: u64,
    echo_bytes: usize,
    delay_ms: u64,
    results_dir: PathBuf,
    static_dir: PathBuf,
    reqwest_pool_max_idle: usize,
    reqwest_connect_timeout_ms: Option<u64>,
    reqwest_tcp_nodelay: Option<bool>,
    reqwest_http2_adaptive_window: Option<bool>,
    rust_clients: Vec<String>,
}

struct WorkerStats {
    total: u64,
    errors: u64,
    latency_sum_us: u128,
    min_us: u64,
    max_us: u64,
    hist: Histogram<u64>,
    error_reasons: HashMap<String, u64>,
}

struct ScenarioStats {
    total: u64,
    errors: u64,
    latency_sum_us: u128,
    min_us: u64,
    max_us: u64,
    hist: Histogram<u64>,
    error_reasons: HashMap<String, u64>,
}

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let config = load_config();
    let scenarios = build_scenarios(&config);

    fs::create_dir_all(&config.results_dir).expect("create results dir");
    write_errors(&config, &[]).expect("write errors");

    let mut results = Vec::new();

    for client_name in &config.rust_clients {
        match client_name.as_str() {
            "reqwest" => {
                let client = build_reqwest_client(&config);
                for scenario in scenarios.clone() {
                    println!(
                        "Running reqwest scenario {} (concurrency={})",
                        scenario.name, config.concurrency
                    );
                    let result = run_scenario_reqwest(&client, &config, scenario).await;
                    log_result(&result);
                    results.push(result);
                }
            }
            "hyper" => {
                let client = build_hyper_client(&config);
                for scenario in scenarios.clone() {
                    println!(
                        "Running hyper scenario {} (concurrency={})",
                        scenario.name, config.concurrency
                    );
                    let result = run_scenario_hyper(&client, &config, scenario).await;
                    log_result(&result);
                    results.push(result);
                }
            }
            other => {
                eprintln!("Unknown rust client: {}", other);
            }
        }
    }

    write_summary(&config, &results).expect("write summary");
    write_metadata(&config, &results).expect("write metadata");
    write_errors(&config, &results).expect("write errors");
}

fn load_config() -> Config {
    let server_host = env_string("BENCH_SERVER_HOST", "localhost");
    let server_port = env_u16("BENCH_SERVER_PORT", 8080);
    let scheme = env_string("BENCH_SCHEME", "http");
    let http_version = env_string("BENCH_HTTP_VERSION", "http1");
    let duration_s = env_u64("BENCH_DURATION", 30);
    let warmup_s = env_u64("BENCH_WARMUP", 5);
    let concurrency = env_usize("BENCH_CONCURRENCY", 100);
    let request_timeout_ms = env_u64("BENCH_REQUEST_TIMEOUT_MS", 30_000);
    let echo_bytes = env_usize("BENCH_ECHO_BYTES", 1024);
    let delay_ms = env_u64("BENCH_DELAY_MS", 100);
    let results_dir = PathBuf::from(env_string("BENCH_RESULTS_DIR", "results/rust"));
    let static_dir = PathBuf::from(env_string(
        "BENCH_STATIC_DIR",
        "../infra/server/static",
    ));
    let reqwest_pool_max_idle =
        env_usize("BENCH_REQWEST_POOL_MAX_IDLE_PER_HOST", concurrency);
    let reqwest_connect_timeout_ms = env_u64_optional("BENCH_REQWEST_CONNECT_TIMEOUT_MS");
    let reqwest_tcp_nodelay = env_bool_optional("BENCH_REQWEST_TCP_NODELAY");
    let reqwest_http2_adaptive_window =
        env_bool_optional("BENCH_REQWEST_HTTP2_ADAPTIVE_WINDOW");
    let rust_clients = env_clients(
        "BENCH_RUST_CLIENTS",
        vec!["reqwest".to_string(), "hyper".to_string()],
    );

    if http_version.to_lowercase() == "http2" && scheme.to_lowercase() != "https" {
        eprintln!("HTTP/2 requires https; set BENCH_SCHEME=https");
        std::process::exit(1);
    }

    Config {
        server_host,
        server_port,
        scheme,
        http_version,
        duration_s,
        warmup_s,
        concurrency,
        request_timeout_ms,
        echo_bytes,
        delay_ms,
        results_dir,
        static_dir,
        reqwest_pool_max_idle,
        reqwest_connect_timeout_ms,
        reqwest_tcp_nodelay,
        reqwest_http2_adaptive_window,
        rust_clients,
    }
}

fn build_reqwest_client(config: &Config) -> Client {
    let mut builder = Client::builder()
        .timeout(Duration::from_millis(config.request_timeout_ms))
        .pool_max_idle_per_host(config.reqwest_pool_max_idle);

    if let Some(timeout_ms) = config.reqwest_connect_timeout_ms {
        builder = builder.connect_timeout(Duration::from_millis(timeout_ms));
    }

    if let Some(tcp_nodelay) = config.reqwest_tcp_nodelay {
        builder = builder.tcp_nodelay(tcp_nodelay);
    }

    if config.http_version.to_lowercase() == "http1" {
        builder = builder.http1_only();
    } else if config.http_version.to_lowercase() == "http2" {
        if config.scheme.to_lowercase() == "http" {
            builder = builder.http2_prior_knowledge();
        }
    }

    if let Some(adaptive) = config.reqwest_http2_adaptive_window {
        builder = builder.http2_adaptive_window(adaptive);
    }

    if config.scheme.to_lowercase() == "https"
        && env_string("BENCH_TLS_VERIFY", "false").to_lowercase() != "true"
    {
        builder = builder.danger_accept_invalid_certs(true);
    }

    builder.build().expect("build reqwest client")
}

fn build_scenarios(config: &Config) -> Vec<Scenario> {
    let echo_body = load_payload(&config.static_dir, config.echo_bytes);
    let json_32k = load_file(&config.static_dir.join("json_32k.json"));
    let rtb_req_1530 = load_file(&config.static_dir.join("rtb_req_1530.json"));

    let mut scenarios = vec![
        Scenario::get("health", "/health", 2),
        Scenario::get("small", "/small", 4096),
        Scenario::get("medium", "/medium", 131_072),
        Scenario::get("large", "/large", 1_048_576),
        Scenario::get("json", "/json", 0),
        Scenario::post("echo", "/echo", echo_body, 0),
        Scenario::get("stream", "/stream", 1_048_576),
        Scenario::get("delay", &format!("/delay/{}", config.delay_ms), 0),
        Scenario::get("delay_var", "/delay_var", 0),
        Scenario::post_json("delay_post", "/delay_post", Bytes::from(json_32k), 0),
        Scenario::post_json("rtb_mix", "/rtb_mix", Bytes::from(rtb_req_1530), 1541),
    ];

    match env::var("BENCH_SCENARIOS") {
        Ok(raw) if raw.trim().eq_ignore_ascii_case("all") => scenarios,
        Ok(raw) if !raw.trim().is_empty() => {
            let wanted: Vec<String> = raw
                .split(',')
                .map(|s| s.trim().to_string())
                .collect();
            scenarios.retain(|s| wanted.iter().any(|w| w == &s.name));
            scenarios
        }
        _ => {
            scenarios.retain(|s| s.name != "large" && s.name != "stream");
            scenarios
        }
    }
}

async fn run_scenario_reqwest(
    client: &Client,
    config: &Config,
    scenario: Scenario,
) -> ScenarioResult {
    let base_url = format!(
        "{}://{}:{}",
        config.scheme, config.server_host, config.server_port
    );
    let warmup_ms = config.warmup_s * 1000;
    if warmup_ms > 0 {
        let _ =
            run_phase_reqwest(client, config, &scenario, &base_url, Duration::from_millis(warmup_ms))
                .await;
    }

    let duration = Duration::from_secs(config.duration_s);
    let start = Instant::now();
    let stats = run_phase_reqwest(client, config, &scenario, &base_url, duration).await;
    let elapsed = start.elapsed().as_secs_f64();

    let rps = if elapsed > 0.0 {
        stats.total as f64 / elapsed
    } else {
        0.0
    };

    let mean_us = if stats.total > 0 {
        (stats.latency_sum_us as f64) / (stats.total as f64)
    } else {
        0.0
    };

    ScenarioResult {
        client: "reqwest".to_string(),
        name: scenario.name,
        requests: stats.total,
        errors: stats.errors,
        duration_s: elapsed,
        rps,
        min_us: if stats.min_us == 0 { None } else { Some(stats.min_us) },
        max_us: if stats.max_us == 0 { None } else { Some(stats.max_us) },
        mean_us: if stats.total > 0 { Some(mean_us) } else { None },
        p50_us: percentile(&stats.hist, 0.50),
        p90_us: percentile(&stats.hist, 0.90),
        p99_us: percentile(&stats.hist, 0.99),
        error_reasons: stats.error_reasons,
    }
}

async fn run_phase_reqwest(
    client: &Client,
    config: &Config,
    scenario: &Scenario,
    base_url: &str,
    duration: Duration,
) -> ScenarioStats {
    let deadline = Instant::now() + duration;
    let mut tasks = JoinSet::new();

    for _ in 0..config.concurrency {
        let client = client.clone();
        let scenario = scenario.clone();
        let base_url = base_url.to_string();
        let timeout_ms = config.request_timeout_ms;
        tasks.spawn(async move {
            worker_loop_reqwest(client, scenario, base_url, deadline, timeout_ms).await
        });
    }

    let mut merged = ScenarioStats::new();
    let join_timeout = Duration::from_secs(20 * 60);
    if tokio::time::timeout(join_timeout, drain_join_set(&mut tasks, &mut merged))
        .await
        .is_err()
    {
        tasks.abort_all();
        drain_join_set(&mut tasks, &mut merged).await;
        merged.errors += 1;
    }

    merged
}

async fn worker_loop_reqwest(
    client: Client,
    scenario: Scenario,
    base_url: String,
    deadline: Instant,
    timeout_ms: u64,
) -> WorkerStats {
    let mut stats = WorkerStats::new();

    while Instant::now() < deadline {
        let start = Instant::now();

        let result = single_request_reqwest(&client, &scenario, &base_url, timeout_ms).await;
        let elapsed_us = start.elapsed().as_micros() as u64;

        if let Err(err) = result {
            stats.errors += 1;
            *stats.error_reasons.entry(err).or_insert(0) += 1;
        } else {
            stats.total += 1;
            stats.latency_sum_us += elapsed_us as u128;
            stats.record_latency(elapsed_us);
        }
    }

    stats
}

async fn single_request_reqwest(
    client: &Client,
    scenario: &Scenario,
    base_url: &str,
    timeout_ms: u64,
) -> Result<(), String> {
    let url = format!("{}{}", base_url, scenario.path);

    let mut req = client.request(scenario.method.clone(), url);
    for (k, v) in &scenario.headers {
        req = req.header(k, v);
    }
    if let Some(body) = &scenario.body {
        req = req.body(body.clone());
    }

    let send = tokio::time::timeout(Duration::from_millis(timeout_ms), req.send()).await;
    let resp = match send {
        Ok(Ok(resp)) => resp,
        Ok(Err(err)) => return Err(err.to_string()),
        Err(_) => return Err("timeout".to_string()),
    };

    let read = tokio::time::timeout(Duration::from_millis(timeout_ms), resp.bytes()).await;
    match read {
        Ok(Ok(_)) => Ok(()),
        Ok(Err(err)) => Err(err.to_string()),
        Err(_) => Err("timeout".to_string()),
    }
}

async fn run_scenario_hyper(
    client: &HyperBenchClient,
    config: &Config,
    scenario: Scenario,
) -> ScenarioResult {
    let base_url = format!(
        "{}://{}:{}",
        config.scheme, config.server_host, config.server_port
    );
    let warmup_ms = config.warmup_s * 1000;
    if warmup_ms > 0 {
        let _ =
            run_phase_hyper(client, config, &scenario, &base_url, Duration::from_millis(warmup_ms))
                .await;
    }

    let duration = Duration::from_secs(config.duration_s);
    let start = Instant::now();
    let stats = run_phase_hyper(client, config, &scenario, &base_url, duration).await;
    let elapsed = start.elapsed().as_secs_f64();

    let rps = if elapsed > 0.0 {
        stats.total as f64 / elapsed
    } else {
        0.0
    };

    let mean_us = if stats.total > 0 {
        (stats.latency_sum_us as f64) / (stats.total as f64)
    } else {
        0.0
    };

    ScenarioResult {
        client: "hyper".to_string(),
        name: scenario.name,
        requests: stats.total,
        errors: stats.errors,
        duration_s: elapsed,
        rps,
        min_us: if stats.min_us == 0 { None } else { Some(stats.min_us) },
        max_us: if stats.max_us == 0 { None } else { Some(stats.max_us) },
        mean_us: if stats.total > 0 { Some(mean_us) } else { None },
        p50_us: percentile(&stats.hist, 0.50),
        p90_us: percentile(&stats.hist, 0.90),
        p99_us: percentile(&stats.hist, 0.99),
        error_reasons: stats.error_reasons,
    }
}

async fn run_phase_hyper(
    client: &HyperBenchClient,
    config: &Config,
    scenario: &Scenario,
    base_url: &str,
    duration: Duration,
) -> ScenarioStats {
    let deadline = Instant::now() + duration;
    let mut tasks = JoinSet::new();

    for _ in 0..config.concurrency {
        let client = client.clone();
        let scenario = scenario.clone();
        let base_url = base_url.to_string();
        let timeout_ms = config.request_timeout_ms;
        tasks.spawn(async move {
            worker_loop_hyper(client, scenario, base_url, deadline, timeout_ms).await
        });
    }

    let mut merged = ScenarioStats::new();
    let join_timeout = Duration::from_secs(20 * 60);
    if tokio::time::timeout(join_timeout, drain_join_set(&mut tasks, &mut merged))
        .await
        .is_err()
    {
        tasks.abort_all();
        drain_join_set(&mut tasks, &mut merged).await;
        merged.errors += 1;
    }

    merged
}

async fn drain_join_set(tasks: &mut JoinSet<WorkerStats>, merged: &mut ScenarioStats) {
    while let Some(result) = tasks.join_next().await {
        match result {
            Ok(stats) => merged.merge(stats),
            Err(_) => {
                merged.errors += 1;
            }
        }
    }
}

async fn worker_loop_hyper(
    client: HyperBenchClient,
    scenario: Scenario,
    base_url: String,
    deadline: Instant,
    timeout_ms: u64,
) -> WorkerStats {
    let mut stats = WorkerStats::new();

    while Instant::now() < deadline {
        let start = Instant::now();

        let result = single_request_hyper(&client, &scenario, &base_url, timeout_ms).await;
        let elapsed_us = start.elapsed().as_micros() as u64;

        if let Err(err) = result {
            stats.errors += 1;
            *stats.error_reasons.entry(err).or_insert(0) += 1;
        } else {
            stats.total += 1;
            stats.latency_sum_us += elapsed_us as u128;
            stats.record_latency(elapsed_us);
        }
    }

    stats
}

async fn single_request_hyper(
    client: &HyperBenchClient,
    scenario: &Scenario,
    base_url: &str,
    timeout_ms: u64,
) -> Result<(), String> {
    let url = format!("{}{}", base_url, scenario.path);
    let uri = url.parse::<http::Uri>().map_err(|e| e.to_string())?;

    let mut builder = Request::builder().method(scenario.method.clone()).uri(uri);
    for (k, v) in &scenario.headers {
        builder = builder.header(k, v);
    }
    let body = scenario.body.clone().unwrap_or_else(Bytes::new);
    let req = builder
        .body(Full::new(body))
        .map_err(|e| e.to_string())?;

    let resp = tokio::time::timeout(Duration::from_millis(timeout_ms), client.request(req))
        .await
        .map_err(|_| "timeout".to_string())?
        .map_err(|e| e.to_string())?;

    let collected = tokio::time::timeout(
        Duration::from_millis(timeout_ms),
        resp.into_body().collect(),
    )
    .await
    .map_err(|_| "timeout".to_string())?
    .map_err(|e| e.to_string())?;

    let _ = collected.to_bytes();

    Ok(())
}

fn percentile(hist: &Histogram<u64>, p: f64) -> Option<f64> {
    if hist.len() == 0 {
        None
    } else {
        Some(hist.value_at_quantile(p) as f64)
    }
}

fn load_payload(dir: &PathBuf, size: usize) -> Bytes {
    let filename = match size {
        1024 => "echo_1024.bin",
        4096 => "small.bin",
        131_072 => "medium.bin",
        1_048_576 => "large.bin",
        _ => panic!("unsupported BENCH_ECHO_BYTES={}", size),
    };
    Bytes::from(load_file(&dir.join(filename)))
}

fn load_file(path: &PathBuf) -> Vec<u8> {
    fs::read(path).unwrap_or_else(|_| panic!("failed to read {}", path.display()))
}

impl Scenario {
    fn get(name: &str, path: &str, response_bytes: usize) -> Self {
        Scenario {
            name: name.to_string(),
            method: Method::GET,
            path: path.to_string(),
            headers: Vec::new(),
            body: None,
            response_bytes,
        }
    }

    fn post(name: &str, path: &str, body: Bytes, response_bytes: usize) -> Self {
        Scenario {
            name: name.to_string(),
            method: Method::POST,
            path: path.to_string(),
            headers: Vec::new(),
            body: Some(body),
            response_bytes,
        }
    }

    fn post_json(name: &str, path: &str, body: Bytes, response_bytes: usize) -> Self {
        Scenario {
            name: name.to_string(),
            method: Method::POST,
            path: path.to_string(),
            headers: vec![("content-type".to_string(), "application/json".to_string())],
            body: Some(body),
            response_bytes,
        }
    }
}

impl WorkerStats {
    fn new() -> Self {
        WorkerStats {
            total: 0,
            errors: 0,
            latency_sum_us: 0,
            min_us: 0,
            max_us: 0,
            hist: Histogram::new_with_bounds(1, 60_000_000, 3).expect("histogram"),
            error_reasons: HashMap::new(),
        }
    }

    fn record_latency(&mut self, latency_us: u64) {
        let value = latency_us.max(1);
        if self.min_us == 0 || value < self.min_us {
            self.min_us = value;
        }
        if value > self.max_us {
            self.max_us = value;
        }
        let _ = self.hist.record(value);
    }
}

impl ScenarioStats {
    fn new() -> Self {
        ScenarioStats {
            total: 0,
            errors: 0,
            latency_sum_us: 0,
            min_us: 0,
            max_us: 0,
            hist: Histogram::new_with_bounds(1, 60_000_000, 3).expect("histogram"),
            error_reasons: HashMap::new(),
        }
    }

    fn merge(&mut self, stats: WorkerStats) {
        self.total += stats.total;
        self.errors += stats.errors;
        self.latency_sum_us += stats.latency_sum_us;
        if self.min_us == 0 || (stats.min_us > 0 && stats.min_us < self.min_us) {
            self.min_us = stats.min_us;
        }
        if stats.max_us > self.max_us {
            self.max_us = stats.max_us;
        }
        let _ = self.hist.add(&stats.hist);
        for (k, v) in stats.error_reasons {
            *self.error_reasons.entry(k).or_insert(0) += v;
        }
    }
}

#[derive(Clone)]
struct ScenarioResult {
    client: String,
    name: String,
    requests: u64,
    errors: u64,
    duration_s: f64,
    rps: f64,
    min_us: Option<u64>,
    max_us: Option<u64>,
    mean_us: Option<f64>,
    p50_us: Option<f64>,
    p90_us: Option<f64>,
    p99_us: Option<f64>,
    error_reasons: HashMap<String, u64>,
}

fn write_summary(config: &Config, results: &[ScenarioResult]) -> csv::Result<()> {
    let path = config.results_dir.join("summary.csv");
    let mut wtr = csv::Writer::from_path(path)?;
    wtr.write_record([
        "client",
        "scenario",
        "requests",
        "errors",
        "duration_seconds",
        "rps",
        "latency_ms_min",
        "latency_ms_max",
        "latency_ms_mean",
        "latency_ms_p50",
        "latency_ms_p90",
        "latency_ms_p99",
    ])?;

    for result in results {
        wtr.write_record([
            result.client.clone(),
            result.name.clone(),
            result.requests.to_string(),
            result.errors.to_string(),
            format_float(result.duration_s),
            format_float(result.rps),
            format_ms(result.min_us),
            format_ms(result.max_us),
            format_ms_f(result.mean_us),
            format_ms_f(result.p50_us),
            format_ms_f(result.p90_us),
            format_ms_f(result.p99_us),
        ])?;
    }

    wtr.flush()?;
    Ok(())
}

fn write_metadata(config: &Config, results: &[ScenarioResult]) -> csv::Result<()> {
    let path = config.results_dir.join("metadata.csv");
    let mut wtr = csv::Writer::from_path(path)?;
    wtr.write_record(["key", "value"])?;

    let now = Utc::now().to_rfc3339();
    write_meta(&mut wtr, "generated_at", &now)?;
    write_meta(&mut wtr, "bench.server_host", &config.server_host)?;
    write_meta(&mut wtr, "bench.server_port", &config.server_port.to_string())?;
    write_meta(&mut wtr, "bench.scheme", &config.scheme)?;
    write_meta(&mut wtr, "bench.http_version", &config.http_version)?;
    write_meta(&mut wtr, "bench.duration_s", &config.duration_s.to_string())?;
    write_meta(&mut wtr, "bench.warmup_s", &config.warmup_s.to_string())?;
    write_meta(&mut wtr, "bench.concurrency", &config.concurrency.to_string())?;
    write_meta(&mut wtr, "bench.request_timeout_ms", &config.request_timeout_ms.to_string())?;
    write_meta(&mut wtr, "bench.echo_bytes", &config.echo_bytes.to_string())?;
    write_meta(&mut wtr, "bench.delay_ms", &config.delay_ms.to_string())?;
    write_meta(
        &mut wtr,
        "reqwest.pool_max_idle_per_host",
        &config.reqwest_pool_max_idle.to_string(),
    )?;
    if let Some(timeout) = config.reqwest_connect_timeout_ms {
        write_meta(&mut wtr, "reqwest.connect_timeout_ms", &timeout.to_string())?;
    }
    if let Some(tcp_nodelay) = config.reqwest_tcp_nodelay {
        write_meta(
            &mut wtr,
            "reqwest.tcp_nodelay",
            &tcp_nodelay.to_string(),
        )?;
    }
    if let Some(adaptive) = config.reqwest_http2_adaptive_window {
        write_meta(
            &mut wtr,
            "reqwest.http2_adaptive_window",
            &adaptive.to_string(),
        )?;
    }

    let scenario_names: Vec<String> = results.iter().map(|r| r.name.clone()).collect();
    write_meta(&mut wtr, "bench.scenarios", &scenario_names.join(","))?;
    write_meta(&mut wtr, "bench.rust_clients", &config.rust_clients.join(","))?;

    wtr.flush()?;
    Ok(())
}

fn write_errors(config: &Config, results: &[ScenarioResult]) -> csv::Result<()> {
    let path = config.results_dir.join("errors.csv");
    let mut wtr = csv::Writer::from_path(path)?;
    wtr.write_record(["client", "scenario", "reason", "count"])?;

    for result in results {
        for (reason, count) in &result.error_reasons {
            wtr.write_record([
                result.client.clone(),
                result.name.clone(),
                reason.clone(),
                count.to_string(),
            ])?;
        }
    }

    wtr.flush()?;
    Ok(())
}

fn write_meta(wtr: &mut csv::Writer<std::fs::File>, key: &str, value: &str) -> csv::Result<()> {
    wtr.write_record([key, value])?;
    Ok(())
}

fn format_float(value: f64) -> String {
    format!("{:.4}", value)
}

fn log_result(result: &ScenarioResult) {
    println!(
        "Completed {} scenario {}: rps={} errors={} p50_ms={} p99_ms={}",
        result.client,
        result.name,
        format_float(result.rps),
        result.errors,
        format_ms_f(result.p50_us),
        format_ms_f(result.p99_us)
    );
}

fn format_ms(value: Option<u64>) -> String {
    match value {
        Some(v) => format!("{:.4}", (v as f64) / 1000.0),
        None => "".to_string(),
    }
}

fn format_ms_f(value: Option<f64>) -> String {
    match value {
        Some(v) => format!("{:.4}", v / 1000.0),
        None => "".to_string(),
    }
}

fn env_string(key: &str, default: &str) -> String {
    env::var(key).unwrap_or_else(|_| default.to_string())
}

fn env_u64(key: &str, default: u64) -> u64 {
    env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn env_u64_optional(key: &str) -> Option<u64> {
    env::var(key).ok().and_then(|v| v.parse().ok())
}

fn env_usize(key: &str, default: usize) -> usize {
    env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn env_bool_optional(key: &str) -> Option<bool> {
    env::var(key).ok().map(|v| matches!(v.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
}

fn env_u16(key: &str, default: u16) -> u16 {
    env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn env_clients(key: &str, default: Vec<String>) -> Vec<String> {
    match env::var(key) {
        Ok(raw) if raw.trim().eq_ignore_ascii_case("all") => {
            vec!["reqwest".to_string(), "hyper".to_string()]
        }
        Ok(raw) if !raw.trim().is_empty() => raw
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect(),
        _ => default,
    }
}

#[derive(Clone)]
enum HyperBenchClient {
    Http(HyperClient<HttpConnector, Full<Bytes>>),
    Https(HyperClient<HttpsConnector<HttpConnector>, Full<Bytes>>),
}

impl HyperBenchClient {
    async fn request(
        &self,
        req: Request<Full<Bytes>>,
    ) -> Result<hyper::Response<hyper::body::Incoming>, hyper_util::client::legacy::Error> {
        match self {
            HyperBenchClient::Http(client) => client.request(req).await,
            HyperBenchClient::Https(client) => client.request(req).await,
        }
    }
}

fn build_hyper_client(config: &Config) -> HyperBenchClient {
    let mut builder = HyperClient::builder(TokioExecutor::new());

    if config.http_version.to_lowercase() == "http2" {
        builder.http2_only(true);
    }

    if config.scheme.to_lowercase() == "https" {
        let mut http = HttpConnector::new();
        http.enforce_http(false);
        let verify = env_string("BENCH_TLS_VERIFY", "false").to_lowercase() == "true";
        let http2 = config.http_version.to_lowercase() == "http2";

        let https = if verify {
            let builder = HttpsConnectorBuilder::new()
                .with_native_roots()
                .expect("no native root certificates found")
                .https_or_http();

            if http2 {
                builder.enable_http2().build()
            } else {
                builder.enable_http1().build()
            }
        } else {
            let tls_config = build_tls_config();
            let builder = HttpsConnectorBuilder::new()
                .with_tls_config(tls_config)
                .https_or_http();

            if http2 {
                builder.enable_http2().build()
            } else {
                builder.enable_http1().build()
            }
        };

        HyperBenchClient::Https(builder.build(https))
    } else {
        let mut http = HttpConnector::new();
        http.enforce_http(false);
        HyperBenchClient::Http(builder.build(http))
    }
}

fn build_tls_config() -> ClientConfig {
    let config = ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(ArcNoVerifier))
        .with_no_client_auth();
    config
}

#[derive(Debug)]
struct ArcNoVerifier;

impl ServerCertVerifier for ArcNoVerifier {
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![
            SignatureScheme::RSA_PKCS1_SHA256,
            SignatureScheme::RSA_PKCS1_SHA384,
            SignatureScheme::RSA_PKCS1_SHA512,
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::ECDSA_NISTP384_SHA384,
            SignatureScheme::ECDSA_NISTP521_SHA512,
            SignatureScheme::ED25519,
        ]
    }

    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, RustlsError> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, RustlsError> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, RustlsError> {
        Ok(HandshakeSignatureValid::assertion())
    }
}
