<#
    PSLite.ps1

    A small web API server for Windows PowerShell 5.1 - like Pode, but one file.
    Built on System.Net.HttpListener (part of .NET), so nothing to install.

        . .\PSLite.ps1

        Add-PlRoute -Method GET -Path '/hello' -Description 'Say hello' -ScriptBlock {
            @{ message = 'hello' }
        }

        Start-PlServer -Port 8080 -ApiKey 'abc123' -LogPath 'C:\logs\mp.log'

    Open http://<server>:8080/docs for the Swagger-like page.
    Ctrl+C stops the server.

    Public functions:
        Add-PlRoute     - add a GET / POST route
        Get-PlRoute     - list the routes added so far
        New-PlResponse  - return your own status code from a route
        Start-PlServer  - start listening (HTTP or HTTPS)
#>

# Routes live here. Dot-sourcing the file again starts with an empty list.
$script:PlRoutes = @()

# Fixed app id used for the HTTPS netsh binding, so you can see which bindings came from PSLite.
$script:PlAppId = '7d3c2a51-6f0e-4b8a-9c1e-2f4d5b6a7c80'

function Add-PlRoute {
<#
.SYNOPSIS
    Adds a route (URL + code to run).

.DESCRIPTION
    The ScriptBlock gets one argument: the request object, with
        .Method .Path .Params .Query .Headers .Body .RawBody .ClientIP

    Params  = values from {name} parts of the path, e.g. /user/{id} -> $Request.Params.id
    Body    = JSON body already turned into an object (when Content-Type is JSON)

    Whatever the ScriptBlock returns is sent back as JSON. A plain string is sent as text.
    Return New-PlResponse to choose your own status code.

    Adding the same Method + Path again replaces the old route.

.PARAMETER Query
    Names of query string parameters. Only used to draw input boxes on the /docs page.

.PARAMETER BodyExample
    Example body (hashtable or object). Only used to pre-fill the body box on the /docs page.

.EXAMPLE
    Add-PlRoute -Method GET -Path '/user/{id}' -Description 'Get one user' -ScriptBlock {
        param($Request)
        @{ id = $Request.Params.id }
    }

.EXAMPLE
    Add-PlRoute -Method POST -Path '/user' -BodyExample @{ name = 'Alex' } -ScriptBlock {
        param($Request)
        @{ added = $Request.Body.name }
    }
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][ValidatePattern('^/')][string]$Path,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$Description = '',
        [string[]]$Query = @(),
        $BodyExample
    )

    $Method = $Method.ToUpper()
    if ($Path.Length -gt 1) { $Path = $Path.TrimEnd('/') }

    # /user/{id}  ->  ^/user/(?<id>[^/]+)/?$
    $pathParams = @([regex]::Matches($Path, '\{(\w+)\}') | ForEach-Object { $_.Groups[1].Value })
    $regex = '^' + ([regex]::Escape($Path) -replace '\\\{(\w+)}', '(?<$1>[^/]+)') + '/?$'

    $bodyJson = ''
    if ($null -ne $BodyExample) { $bodyJson = ConvertTo-Json -InputObject $BodyExample -Depth 10 }

    $route = [pscustomobject]@{
        Method      = $Method
        Path        = $Path
        Description = $Description
        Query       = @($Query)
        PathParams  = $pathParams
        BodyExample = $bodyJson
        Regex       = $regex
        ScriptBlock = $ScriptBlock
    }

    $script:PlRoutes = @($script:PlRoutes | Where-Object { -not ($_.Method -eq $Method -and $_.Path -eq $Path) }) + $route
}

function Get-PlRoute {
<#
.SYNOPSIS
    Lists the routes added so far.
#>
    [CmdletBinding()]
    param()

    $script:PlRoutes | Select-Object Method, Path, Description
}

function New-PlResponse {
<#
.SYNOPSIS
    Return this from a route to set your own status code.

.EXAMPLE
    Add-PlRoute -Method GET -Path '/user/{id}' -ScriptBlock {
        param($Request)
        $user = Get-ADUser -Filter "SamAccountName -eq '$($Request.Params.id)'"
        if (-not $user) { return New-PlResponse -StatusCode 404 -Body @{ error = 'User not found' } }
        $user | Select-Object Name, SamAccountName
    }

.EXAMPLE
    # Serve an HTML page (Body must be a string when -ContentType is used)
    Add-PlRoute -Method GET -Path '/' -ScriptBlock {
        New-PlResponse -StatusCode 200 -ContentType 'text/html' -Body (Get-Content 'C:\web\page.html' -Raw)
    }
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        $Body,
        [string]$ContentType
    )

    [pscustomobject]@{
        PSTypeName  = 'PlResponse'
        StatusCode  = $StatusCode
        Body        = $Body
        ContentType = $ContentType
    }
}

function Start-PlServer {
<#
.SYNOPSIS
    Starts the web server. Runs until Ctrl+C.

.DESCRIPTION
    Handles one request at a time.

    Built-in pages:
        /docs   Swagger-like page, open to everyone (the API key is typed into the page).
        /       Goes to /docs, unless you added your own '/' route.

    -Hostname '+' (default) listens on every IP / name of the server. That needs PowerShell
    run as admin, or a one-time URL reservation (as admin):
        netsh http add urlacl url=http://+:8080/ user=DOMAIN\you
    -Hostname localhost works without admin, but only from the same machine.

    -Https binds the certificate to the port with netsh (needs admin the first time).
    The certificate must be in Cert:\LocalMachine\My and have a private key.
    If the port is already bound to a different certificate, nothing is changed and an error
    is shown - so another app's binding is never overwritten.

.PARAMETER ApiKey
    If set, every route needs header X-API-Key with this value. Without it there is no auth.

.PARAMETER LogPath
    If set, one line per request is added to this file. The folder is created if missing.

.EXAMPLE
    Start-PlServer -Port 8080 -Hostname localhost

.EXAMPLE
    Start-PlServer -Port 8443 -Https -CertThumbprint 'A1B2...' -ApiKey 'abc123' -LogPath 'C:\logs\mp.log'
#>
    [CmdletBinding()]
    param(
        [int]$Port = 8080,
        [string]$Hostname = '+',
        [switch]$Https,
        [string]$CertThumbprint,
        [string]$ApiKey,
        [string]$LogPath,
        [string]$Title = 'PSLite API'
    )

    if ($Https) {
        if (-not $CertThumbprint) { throw "-Https needs -CertThumbprint." }
        Set-PlSslBinding -Port $Port -CertThumbprint $CertThumbprint
    }

    if ($LogPath) {
        $logDir = Split-Path -Path $LogPath -Parent
        if ($logDir -and -not (Test-Path -Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    }

    $scheme = if ($Https) { 'https' } else { 'http' }
    $prefix = "{0}://{1}:{2}/" -f $scheme, $Hostname, $Port

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)

    try {
        $listener.Start()
    }
    catch {
        $listener.Close()
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        if ($msg -match 'denied') {
            throw ("Access denied on $prefix. Run PowerShell as admin, or use -Hostname localhost, " +
                   "or once as admin: netsh http add urlacl url=$prefix user=$env:USERDOMAIN\$env:USERNAME")
        }
        throw "Could not start on $prefix : $msg (is the port already in use?)"
    }

    $shownHost = if ($Hostname -in '+', '*') { $env:COMPUTERNAME } else { $Hostname }
    $baseUrl = "{0}://{1}:{2}" -f $scheme, $shownHost, $Port

    Write-Host ""
    Write-Host "PSLite listening on $prefix" -ForegroundColor Green
    Write-Host "  Docs   : $baseUrl/docs" -ForegroundColor Cyan
    Write-Host "  Routes : $(@($script:PlRoutes).Count)"
    Write-Host "  Auth   : $(if ($ApiKey) { 'API key (header X-API-Key)' } else { 'none' })"
    Write-Host "  Log    : $(if ($LogPath) { $LogPath } else { 'none' })"
    Write-Host "Ctrl+C to stop." -ForegroundColor Yellow
    Write-Host ""

    Write-PlLog -LogPath $LogPath -Line ("{0} | SERVER STARTED | {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $prefix)

    try {
        while ($listener.IsListening) {
            # Wait in short steps so Ctrl+C can break in (a plain GetContext() would block it).
            $task = $listener.GetContextAsync()
            while (-not $task.AsyncWaitHandle.WaitOne(500)) { }

            Invoke-PlRequest -Context $task.Result -ApiKey $ApiKey -LogPath $LogPath -Title $Title
        }
    }
    finally {
        $listener.Stop()
        $listener.Close()
        Write-PlLog -LogPath $LogPath -Line ("{0} | SERVER STOPPED | {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $prefix)
        Write-Host "PSLite stopped." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Internal helpers (not meant to be called directly)
# ---------------------------------------------------------------------------

function Invoke-PlRequest {
    param($Context, [string]$ApiKey, [string]$LogPath, [string]$Title)

    $ErrorActionPreference = 'Stop'
    $req    = $Context.Request
    $method = $req.HttpMethod
    $path   = $req.Url.AbsolutePath
    if ($path.Length -gt 1) { $path = $path.TrimEnd('/') }
    $clientIp = $req.RemoteEndPoint.Address.ToString()   # read now - it is gone once the response is closed
    $status = 500
    $sw     = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # --- built-in pages ---
        if ($method -eq 'GET' -and $path -eq '/docs') {
            $status = 200
            Send-PlResponse -Context $Context -StatusCode $status -ContentType 'text/html' -Text (Get-PlDocsHtml -Title $Title)
            return
        }

        if ($method -eq 'GET' -and $path -eq '/' -and -not ($script:PlRoutes | Where-Object { $_.Method -eq 'GET' -and $_.Path -eq '/' })) {
            $status = 302
            $Context.Response.Redirect('/docs')
            $Context.Response.Close()
            return
        }

        # --- auth ---
        if ($ApiKey -and $req.Headers['X-API-Key'] -cne $ApiKey) {
            $status = 401
            Send-PlJson -Context $Context -StatusCode $status -Object @{ error = 'Missing or wrong API key (header X-API-Key).' }
            return
        }

        # --- find route ---
        $route = $null
        $pathParams = @{}
        foreach ($r in $script:PlRoutes) {
            if ($r.Method -eq $method -and $path -match $r.Regex) {
                $route = $r
                foreach ($k in $Matches.Keys) {
                    if ($k -ne 0) { $pathParams[$k] = [uri]::UnescapeDataString($Matches[$k]) }
                }
                break
            }
        }

        if (-not $route) {
            $status = 404
            Send-PlJson -Context $Context -StatusCode $status -Object @{ error = "No route for $method $path" }
            return
        }

        # --- read request ---
        $query = @{}
        foreach ($k in $req.QueryString.AllKeys) { if ($k) { $query[$k] = $req.QueryString[$k] } }

        $headers = @{}
        foreach ($k in $req.Headers.AllKeys) { $headers[$k] = $req.Headers[$k] }

        $rawBody = $null
        if ($req.HasEntityBody) {
            $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
            try { $rawBody = $reader.ReadToEnd() } finally { $reader.Close() }
        }

        $body = $rawBody
        if ($rawBody -and $req.ContentType -like '*json*') {
            try {
                $body = $rawBody | ConvertFrom-Json
            }
            catch {
                $status = 400
                Send-PlJson -Context $Context -StatusCode $status -Object @{ error = "Body is not valid JSON: $($_.Exception.Message)" }
                return
            }
        }

        $request = [pscustomobject]@{
            Method   = $method
            Path     = $path
            Params   = $pathParams
            Query    = $query
            Headers  = $headers
            Body     = $body
            RawBody  = $rawBody
            ClientIP = $clientIp
        }

        # --- run the route ---
        $result = @(& $route.ScriptBlock $request)

        $code = 200
        $contentType = 'text/plain'
        if ($result.Count -eq 1 -and $result[0] -and $result[0].PSObject.TypeNames -contains 'PlResponse') {
            $code = $result[0].StatusCode
            if ($result[0].ContentType) { $contentType = $result[0].ContentType }
            $result = @($result[0].Body)
        }

        $status = $code
        if ($result.Count -eq 0 -or ($result.Count -eq 1 -and $null -eq $result[0])) {
            if ($status -eq 200) { $status = 204 }
            Send-PlResponse -Context $Context -StatusCode $status
        }
        elseif ($result.Count -eq 1 -and $result[0] -is [string]) {
            Send-PlResponse -Context $Context -StatusCode $status -ContentType $contentType -Text $result[0]
        }
        elseif ($result.Count -eq 1) {
            Send-PlJson -Context $Context -StatusCode $status -Object $result[0]
        }
        else {
            Send-PlJson -Context $Context -StatusCode $status -Object $result
        }
    }
    catch {
        $status = 500
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Send-PlJson -Context $Context -StatusCode $status -Object @{ error = $_.Exception.Message }
    }
    finally {
        $sw.Stop()
        $line = "{0} | {1} | {2} {3} | {4} | {5} ms" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $clientIp, $method, $req.Url.PathAndQuery, $status, $sw.ElapsedMilliseconds

        $color = if ($status -ge 500) { 'Red' } elseif ($status -ge 400) { 'Yellow' } else { 'Gray' }
        Write-Host $line -ForegroundColor $color
        Write-PlLog -LogPath $LogPath -Line $line
    }
}

function Send-PlResponse {
    param($Context, [int]$StatusCode, [string]$ContentType = 'text/plain', [string]$Text)

    $res = $Context.Response
    try {
        $res.StatusCode = $StatusCode
        if ($Text) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
            $res.ContentType = "$ContentType; charset=utf-8"
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        }
    }
    catch {
        Write-Warning "Could not send response: $($_.Exception.Message)"
    }
    finally {
        $res.Close()
    }
}

function Send-PlJson {
    param($Context, [int]$StatusCode, $Object)

    $json = ConvertTo-Json -InputObject $Object -Depth 10
    Send-PlResponse -Context $Context -StatusCode $StatusCode -ContentType 'application/json' -Text $json
}

function Write-PlLog {
    param([string]$LogPath, [string]$Line)

    if (-not $LogPath) { return }
    try { Add-Content -Path $LogPath -Value $Line -Encoding UTF8 }
    catch { Write-Warning "Could not write log: $($_.Exception.Message)" }
}

function Set-PlSslBinding {
    param([int]$Port, [string]$CertThumbprint)

    # Copy-paste from the cert window often adds hidden characters - keep only hex.
    $thumb = ($CertThumbprint -replace '[^0-9a-fA-F]', '').ToUpper()

    $cert = Get-Item -Path "Cert:\LocalMachine\My\$thumb" -ErrorAction SilentlyContinue
    if (-not $cert)               { throw "Certificate $thumb not found in Cert:\LocalMachine\My." }
    if (-not $cert.HasPrivateKey) { throw "Certificate $thumb has no private key - it cannot be used for HTTPS." }

    $ipport = "0.0.0.0:$Port"
    $show = netsh http show sslcert "ipport=$ipport" 2>&1 | Out-String

    if ($show -match 'Certificate Hash\s*:\s*([0-9a-fA-F]+)') {
        $current = $Matches[1].ToUpper()
        if ($current -eq $thumb) {
            Write-Host "HTTPS: port $Port already bound to certificate $thumb." -ForegroundColor Gray
            return
        }
        throw ("Port $Port is already bound to another certificate ($current). Not changing it. " +
               "If it is safe to remove, run as admin: netsh http delete sslcert ipport=$ipport")
    }

    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Binding the certificate to port $Port needs PowerShell run as admin (only the first time)."
    }

    $out = netsh http add sslcert "ipport=$ipport" "certhash=$thumb" "appid={$script:PlAppId}" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "netsh could not bind the certificate: $out" }

    Write-Host "HTTPS: bound certificate $thumb to port $Port." -ForegroundColor Green
}

function Get-PlDocsHtml {
    param([string]$Title)

    $data = @($script:PlRoutes | ForEach-Object {
        [ordered]@{
            Method      = $_.Method
            Path        = $_.Path
            Description = $_.Description
            PathParams  = @($_.PathParams)
            Query       = @($_.Query)
            BodyExample = $_.BodyExample
        }
    })

    $json = if ($data.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $data -Depth 5 -Compress }
    $json = $json.Replace('</', '<\/')

    $html = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
  body { font-family: "Segoe UI", Arial, sans-serif; margin: 0; background: #fafafa; color: #3b4151; }
  header { background: #1b1b1b; color: #fff; padding: 14px 24px; display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  header h1 { font-size: 20px; margin: 0; flex: 1; }
  header input { padding: 6px 8px; width: 220px; border: 0; border-radius: 3px; }
  header button { padding: 6px 14px; border: 1px solid #49cc90; background: transparent; color: #49cc90; border-radius: 3px; cursor: pointer; font-weight: 600; }
  #saved { font-size: 12px; color: #49cc90; }
  main { max-width: 1000px; margin: 20px auto; padding: 0 16px; }
  .op { border: 1px solid; border-radius: 4px; margin-bottom: 10px; }
  .op.GET  { border-color: #61affe; background: rgba(97,175,254,.1); }
  .op.POST { border-color: #49cc90; background: rgba(73,204,144,.1); }
  .sum { display: flex; align-items: center; gap: 12px; padding: 8px; cursor: pointer; }
  .badge { min-width: 64px; text-align: center; color: #fff; font-weight: 700; border-radius: 3px; padding: 6px 0; font-size: 14px; }
  .GET .badge  { background: #61affe; }
  .POST .badge { background: #49cc90; }
  .path { font-family: Consolas, monospace; font-weight: 700; font-size: 15px; }
  .desc { color: #555; font-size: 13px; }
  .body { display: none; padding: 12px 16px; border-top: 1px solid #ddd; background: #fff; }
  .op.open .body { display: block; }
  label { display: block; font-size: 13px; font-weight: 600; margin: 10px 0 4px; }
  input.p { padding: 5px 8px; width: 300px; max-width: 100%; border: 1px solid #ccc; border-radius: 3px; }
  textarea { width: 100%; box-sizing: border-box; height: 120px; font-family: Consolas, monospace; font-size: 13px; }
  pre { background: #333; color: #fff; padding: 10px; border-radius: 4px; overflow: auto; white-space: pre-wrap; word-break: break-all; font-size: 13px; margin: 0; }
  .exec { background: #4990e2; color: #fff; border: 0; padding: 8px 24px; border-radius: 4px; margin-top: 12px; cursor: pointer; font-weight: 600; }
  .empty { color: #888; }
</style>
</head>
<body>
<header>
  <h1>__TITLE__</h1>
  <span id="saved"></span>
  <input id="key" type="password" placeholder="API key (X-API-Key)">
  <button id="auth">Authorize</button>
</header>
<main id="list"></main>
<script>
var routes = __ROUTES__;
var keyBox = document.getElementById('key');
try { keyBox.value = localStorage.getItem('psLiteKey') || ''; } catch (e) {}
document.getElementById('auth').onclick = function () {
  try { localStorage.setItem('psLiteKey', keyBox.value); } catch (e) {}
  document.getElementById('saved').textContent = keyBox.value ? 'Key saved' : 'Key cleared';
};

function el(tag, cls, text) {
  var e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

function psCommand(url, method, body) {
  var cmd = "Invoke-RestMethod -Method " + method + " -Uri '" + location.origin + url + "'";
  if (keyBox.value) cmd += " -Headers @{ 'X-API-Key' = '<your key>' }";
  if (body) cmd += " -ContentType 'application/json' -Body '" + body.replace(/'/g, "''") + "'";
  return cmd;
}

var list = document.getElementById('list');
if (!routes.length) list.appendChild(el('p', 'empty', 'No routes yet. Add some with Add-PlRoute.'));

routes.forEach(function (r) {
  var op = el('div', 'op ' + r.Method);
  var sum = el('div', 'sum');
  sum.appendChild(el('span', 'badge', r.Method));
  sum.appendChild(el('span', 'path', r.Path));
  sum.appendChild(el('span', 'desc', r.Description || ''));
  sum.onclick = function () { op.classList.toggle('open'); };

  var b = el('div', 'body');
  var pathBoxes = {}, queryBoxes = {}, bodyBox = null;

  (r.PathParams || []).forEach(function (n) {
    b.appendChild(el('label', null, n + '  (path, required)'));
    pathBoxes[n] = b.appendChild(el('input', 'p'));
  });
  (r.Query || []).forEach(function (n) {
    b.appendChild(el('label', null, n + '  (query)'));
    queryBoxes[n] = b.appendChild(el('input', 'p'));
  });
  if (r.Method !== 'GET') {
    b.appendChild(el('label', null, 'Body (JSON)'));
    bodyBox = b.appendChild(el('textarea'));
    bodyBox.value = r.BodyExample || '';
  }

  var btn = b.appendChild(el('button', 'exec', 'Execute'));
  var out = b.appendChild(el('div'));

  btn.onclick = function () {
    var url = r.Path.replace(/\{(\w+)\}/g, function (m, n) { return encodeURIComponent(pathBoxes[n].value); });
    var qs = [];
    for (var n in queryBoxes) {
      if (queryBoxes[n].value !== '') qs.push(encodeURIComponent(n) + '=' + encodeURIComponent(queryBoxes[n].value));
    }
    if (qs.length) url += '?' + qs.join('&');

    var opts = { method: r.Method, headers: {} };
    if (keyBox.value) opts.headers['X-API-Key'] = keyBox.value;
    if (bodyBox && bodyBox.value.trim()) {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = bodyBox.value;
    }

    out.innerHTML = '';
    out.appendChild(el('label', null, 'PowerShell'));
    out.appendChild(el('pre', null, psCommand(url, r.Method, opts.body)));

    var t0 = Date.now();
    fetch(url, opts).then(function (res) {
      return res.text().then(function (txt) {
        var pretty = txt;
        try { pretty = JSON.stringify(JSON.parse(txt), null, 2); } catch (e) {}
        out.appendChild(el('label', null, 'Response: ' + res.status + ' ' + res.statusText + '  (' + (Date.now() - t0) + ' ms)'));
        out.appendChild(el('pre', null, pretty || '(empty)'));
      });
    }).catch(function (e) {
      out.appendChild(el('label', null, 'Error'));
      out.appendChild(el('pre', null, String(e)));
    });
  };

  op.appendChild(sum);
  op.appendChild(b);
  list.appendChild(op);
});
</script>
</body>
</html>
'@

    $safeTitle = [System.Net.WebUtility]::HtmlEncode($Title)
    $html.Replace('__TITLE__', $safeTitle).Replace('__ROUTES__', $json)
}
