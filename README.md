# PSLite

PSLite is a small web API server for Windows PowerShell 5.1. It works like Pode, but it's one file.

It's built on `System.Net.HttpListener`, so there's nothing to install. The `/docs` page is like Swagger and works offline.

**Watch the demo (1:19, sound on): https://suhailasrulsani-git.github.io/pslite/PSLite-demo.mp4**

## Install

It's on the PowerShell Gallery: https://www.powershellgallery.com/packages/PSLite

```powershell
Install-Module PSLite -Scope CurrentUser
```

Or download `PSLite.ps1` and dot-source it (`. .\PSLite.ps1`). Both work the same.

## Quick start

```powershell
Import-Module PSLite

Add-PlRoute -Method GET -Path '/hello' -Description 'Say hello' -ScriptBlock {
    @{ message = 'hello' }
}

Start-PlServer -Port 8080 -Hostname localhost
```

Open `http://localhost:8080/docs`. Press Ctrl+C to stop.

## Features

- GET and POST routes, path values like `/user/{id}`, query strings, JSON body
- Whatever your route returns is sent back as JSON (a plain string is sent as text)
- `/docs` page: try each route, see the response and the matching `Invoke-RestMethod` command
- Optional API key (header `X-API-Key`)
- Optional log file, one line per request
- HTTP or HTTPS. It never overwrites another app's certificate binding.

## Functions

| Function | What it does |
|---|---|
| `Add-PlRoute` | Add a GET / POST route |
| `Get-PlRoute` | List the routes added so far |
| `New-PlResponse` | Return your own status code (and content type) from a route |
| `Start-PlServer` | Start listening. Runs until Ctrl+C. |

## Examples

```powershell
# Path value + your own status code
Add-PlRoute -Method GET -Path '/service/{name}' -Description 'Status of one service' -ScriptBlock {
    param($Request)
    $svc = Get-Service -Name $Request.Params.name -ErrorAction SilentlyContinue
    if (-not $svc) { return New-PlResponse -StatusCode 404 -Body @{ error = 'Not found' } }
    @{ name = $svc.Name; status = $svc.Status.ToString() }
}

# POST with a JSON body
Add-PlRoute -Method POST -Path '/echo' -BodyExample @{ name = 'Alex' } -ScriptBlock {
    param($Request)
    @{ youSent = $Request.Body }
}

# API key + log file
Start-PlServer -Port 8080 -ApiKey 'abc123' -LogPath 'C:\logs\pslite.log'

# HTTPS (cert must be in Cert:\LocalMachine\My with a private key)
Start-PlServer -Port 8443 -Https -CertThumbprint '<thumbprint>'
```

The request object has `.Method .Path .Params .Query .Headers .Body .RawBody .ClientIP`.

## Notes

- `-Hostname '+'` (the default) listens on every name of the server. It needs admin, or this one-time command run as admin:
  `netsh http add urlacl url=http://+:8080/ user=DOMAIN\you`
- `-Hostname localhost` works without admin, but only from the same machine.
- It handles one request at a time.
- It needs FullLanguage mode. It won't run under Constrained Language Mode.

## Demo

```powershell
.\Demo.ps1
```

Then open `http://localhost:8080/docs`. The API key for the demo is `demo123`.

## License

MIT - see [LICENSE](LICENSE).
