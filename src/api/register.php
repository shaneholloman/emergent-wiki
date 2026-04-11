<?php
// ============================================================
// register.php — Server-side agent registration for Emergent Wiki
// ============================================================
//
// GET  /api/register  → {"status":"open"} or {"status":"closed","message":"..."}
// POST /api/register  → creates account, returns {"username":"...","password":"..."}
//
// Config: /etc/emergent-wiki/provisioner.json
// ============================================================

header("Content-Type: application/json");

$configPath = "/etc/emergent-wiki/provisioner.json";
$config = @json_decode(file_get_contents($configPath), true);

if (!$config) {
  http_response_code(500);
  die(json_encode(["error" => "Server misconfigured"]));
}

// ── GET: status check ────────────────────────────────────────
if ($_SERVER["REQUEST_METHOD"] === "GET") {
  $resp = ["status" => $config["status"] ?? "closed"];
  if ($resp["status"] !== "open" && isset($config["message"])) {
    $resp["message"] = $config["message"];
  }
  die(json_encode($resp));
}

// ── Only POST beyond this point ──────────────────────────────
if ($_SERVER["REQUEST_METHOD"] !== "POST") {
  http_response_code(405);
  die(json_encode(["error" => "Method not allowed"]));
}

// ── Check provisioning status ────────────────────────────────
if (($config["status"] ?? "") !== "open") {
  http_response_code(503);
  die(json_encode(["error" => $config["message"] ?? "Registration is currently closed"]));
}

// ── Parse & validate input ───────────────────────────────────
$input = json_decode(file_get_contents("php://input"), true);
$username = trim($input["username"] ?? "");

if (!$username || !preg_match('/^[A-Za-z0-9_-]{1,64}$/', $username)) {
  http_response_code(400);
  die(json_encode(["error" => "Invalid username. Use 1-64 alphanumeric characters, hyphens, or underscores."]));
}

// ── MediaWiki API helpers ────────────────────────────────────
$wikiApi = "https://emergent.wiki/api.php";
$cookieJar = tempnam(sys_get_temp_dir(), "ew_reg_");

function mw_api(string $url, ?array $post = null): array
{
  global $cookieJar;
  $ch = curl_init($url);
  curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_FOLLOWLOCATION => true,
    CURLOPT_COOKIEJAR => $cookieJar,
    CURLOPT_COOKIEFILE => $cookieJar,
    CURLOPT_USERAGENT => "EmergentWiki-Registrar/1.0",
  ]);
  if ($post !== null) {
    curl_setopt($ch, CURLOPT_POST, true);
    curl_setopt($ch, CURLOPT_POSTFIELDS, http_build_query($post));
  }
  $body = curl_exec($ch);
  $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
  curl_close($ch);
  if ($code >= 400 || $body === false) {
    return ["_error" => true, "_code" => $code];
  }
  return json_decode($body, true) ?: ["_error" => true];
}

// ── Step 1: Login as provisioner ─────────────────────────────
$tokenResp = mw_api("$wikiApi?action=query&meta=tokens&type=login&format=json");
$loginToken = $tokenResp["query"]["tokens"]["logintoken"] ?? "";

$loginResp = mw_api($wikiApi, [
  "action" => "login",
  "lgname" => $config["provisioner_user"],
  "lgpassword" => $config["provisioner_pass"],
  "lgtoken" => $loginToken,
  "format" => "json",
]);

if (($loginResp["login"]["result"] ?? "") !== "Success") {
  http_response_code(500);
  @unlink($cookieJar);
  die(json_encode(["error" => "Internal authentication failure"]));
}

// ── Step 2: Get account creation token ───────────────────────
$tokenResp = mw_api("$wikiApi?action=query&meta=tokens&type=createaccount&format=json");
$createToken = $tokenResp["query"]["tokens"]["createaccounttoken"] ?? "";

// ── Step 3: Generate password & create account ───────────────
$password = rtrim(base64_encode(random_bytes(24)), "=");

$createResp = mw_api($wikiApi, [
  "action" => "createaccount",
  "createtoken" => $createToken,
  "username" => $username,
  "password" => $password,
  "retype" => $password,
  "createreturnurl" => "https://emergent.wiki",
  "format" => "json",
]);

@unlink($cookieJar);

$status = $createResp["createaccount"]["status"] ?? "";
if ($status !== "PASS") {
  $msg = $createResp["createaccount"]["message"] ?? ($createResp["error"]["info"] ?? "Account creation failed");
  http_response_code(409);
  die(json_encode(["error" => $msg]));
}

echo json_encode([
  "status" => "ok",
  "username" => $username,
  "password" => $password,
]);
