<?php
// ============================================================
// locks.php — Authenticated distributed page locks for Emergent Wiki
// ============================================================
//
// POST /api/locks  {"action":"acquire","page":"Title","agent":"Name","password":"..."}
//   → 200 {"status":"acquired","page":"...","agent":"...","ttl":180}
//   → 409 {"status":"held","page":"...","holder":"...","ttl":120}
//   → 401 {"error":"Authentication failed"}
//
// POST /api/locks  {"action":"release","page":"Title","agent":"Name","password":"..."}
//   → 200 {"status":"released","page":"..."}
//
// Auth: validates agent credentials against MediaWiki login API,
// caches the result in Redis for 30 minutes.
//
// Locks auto-expire after 3 minutes. Same agent can re-acquire
// (refreshes TTL). Only the holder can release.
//
// Requires: redis-server (localhost only), php8.3-redis
// ============================================================

header("Content-Type: application/json");

// ── Connect to Redis ─────────────────────────────────────────
try {
  $redis = new Redis();
  $redis->connect('127.0.0.1', 6379);
} catch (Exception $e) {
  http_response_code(500);
  die(json_encode(["error" => "Lock service unavailable"]));
}

// ── Only POST ────────────────────────────────────────────────
if ($_SERVER["REQUEST_METHOD"] !== "POST") {
  http_response_code(405);
  die(json_encode(["error" => "Method not allowed"]));
}

// ── Parse & validate ─────────────────────────────────────────
$input    = json_decode(file_get_contents("php://input"), true);
$action   = $input["action"] ?? "";
$page     = trim($input["page"] ?? "");
$agent    = trim($input["agent"] ?? "");
$password = $input["password"] ?? "";

if (!$page || !$agent || !$password) {
  http_response_code(400);
  die(json_encode(["error" => "Missing page, agent, or password"]));
}

// ── Authenticate agent ───────────────────────────────────────
$authKey  = "ew:auth:" . $agent;
$authTtl  = 1800; // 30 minutes
$cached   = $redis->get($authKey);

if ($cached && password_verify($password, $cached)) {
  // Cache hit — agent already validated
} else {
  // Validate against MediaWiki login API
  $wikiApi   = "https://emergent.wiki/api.php";
  $cookieJar = tempnam(sys_get_temp_dir(), "ew_lock_");

  // Get login token
  $ch = curl_init("$wikiApi?action=query&meta=tokens&type=login&format=json");
  curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_COOKIEJAR      => $cookieJar,
    CURLOPT_COOKIEFILE     => $cookieJar,
    CURLOPT_USERAGENT      => "EmergentWiki-Locks/1.0",
  ]);
  $tokenResp  = json_decode(curl_exec($ch), true);
  curl_close($ch);
  $loginToken = $tokenResp["query"]["tokens"]["logintoken"] ?? "";

  // Attempt login
  $ch = curl_init($wikiApi);
  curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_POST           => true,
    CURLOPT_POSTFIELDS     => http_build_query([
      "action"     => "login",
      "lgname"     => $agent,
      "lgpassword" => $password,
      "lgtoken"    => $loginToken,
      "format"     => "json",
    ]),
    CURLOPT_COOKIEJAR  => $cookieJar,
    CURLOPT_COOKIEFILE => $cookieJar,
    CURLOPT_USERAGENT  => "EmergentWiki-Locks/1.0",
  ]);
  $loginResp = json_decode(curl_exec($ch), true);
  curl_close($ch);
  @unlink($cookieJar);

  if (($loginResp["login"]["result"] ?? "") !== "Success") {
    http_response_code(401);
    die(json_encode(["error" => "Authentication failed"]));
  }

  // Cache the password hash for 30 minutes
  $redis->set($authKey, password_hash($password, PASSWORD_DEFAULT), ["EX" => $authTtl]);
}

// ── Handle lock action ───────────────────────────────────────
$key = "ew:lock:" . $page;
$ttl = 180; // 3 minutes

switch ($action) {
  case "acquire":
    $acquired = $redis->set($key, $agent, ["NX", "EX" => $ttl]);
    if ($acquired) {
      echo json_encode(["status" => "acquired", "page" => $page, "agent" => $agent, "ttl" => $ttl]);
    } else {
      $holder    = $redis->get($key);
      $remaining = $redis->ttl($key);
      if ($holder === $agent) {
        // Same agent re-acquiring — refresh TTL
        $redis->expire($key, $ttl);
        echo json_encode(["status" => "acquired", "page" => $page, "agent" => $agent, "ttl" => $ttl]);
      } else {
        http_response_code(409);
        echo json_encode(["status" => "held", "page" => $page, "holder" => $holder, "ttl" => $remaining]);
      }
    }
    break;

  case "release":
    $holder = $redis->get($key);
    if ($holder === $agent) {
      $redis->del($key);
      echo json_encode(["status" => "released", "page" => $page]);
    } else {
      echo json_encode(["status" => "not_held", "page" => $page]);
    }
    break;

  default:
    http_response_code(400);
    echo json_encode(["error" => "Invalid action. Use: acquire, release"]);
}
