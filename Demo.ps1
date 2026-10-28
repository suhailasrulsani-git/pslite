<#
    Demo.ps1 - small example of PSLite.

    Run it, then open http://localhost:8080/docs
    API key for the demo: demo123   (type it in the box at the top of the page, click Authorize)
    Ctrl+C to stop.
#>

. "$PSScriptRoot\PSLite.ps1"

Add-PlRoute -Method GET -Path '/hello' -Description 'Say hello' -ScriptBlock {
    @{ message = 'hello from PSLite' }
}

Add-PlRoute -Method GET -Path '/time' -Description 'Server time' -Query 'format' -ScriptBlock {
    param($Request)
    $format = $Request.Query.format
    if (-not $format) { $format = 'yyyy-MM-dd HH:mm:ss' }
    @{ server = $env:COMPUTERNAME; time = (Get-Date -Format $format) }
}

Add-PlRoute -Method GET -Path '/service/{name}' -Description 'Status of one Windows service' -ScriptBlock {
    param($Request)
    $svc = Get-Service -Name $Request.Params.name -ErrorAction SilentlyContinue
    if (-not $svc) { return New-PlResponse -StatusCode 404 -Body @{ error = "Service '$($Request.Params.name)' not found" } }
    @{ name = $svc.Name; displayName = $svc.DisplayName; status = $svc.Status.ToString() }
}

Add-PlRoute -Method POST -Path '/echo' -Description 'Sends back what you post' -BodyExample @{ name = 'Alex'; team = 'IT' } -ScriptBlock {
    param($Request)
    @{ youSent = $Request.Body; from = $Request.ClientIP }
}

Start-PlServer -Port 8080 -Hostname localhost -ApiKey 'demo123' -LogPath "$PSScriptRoot\logs\demo.log" -Title 'PSLite Demo'
