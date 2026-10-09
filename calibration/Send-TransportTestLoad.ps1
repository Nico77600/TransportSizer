<#
.SYNOPSIS
    Transport Sizer - calibration: sends a steady SMTP load to a transport server, step by step.

.DESCRIPTION
    Runs on another computer than the measured server (its CPU must not be measured with the load). For
    each rate of -Rates, sends messages (text body of -MessageSizeKB, attachment of -AttachmentKB, a mix of
    sizes with -AttachmentWeight) during -StepSeconds over several SMTP sessions kept open (one message after
    the other, RSET between them, or a new session every -MessagesPerSession messages), paced to the rate
    asked, then waits -PauseSeconds. Prints and returns the rate actually reached by each step, the average
    size of the messages sent and the sessions opened.

    With -Count, sends exactly that number of messages at the first rate, then stops (Backlog step: the
    queue of the next hop is suspended on the measured server, the messages accumulate there).

    Every message carries the header X-TransportSizer-Calibration: <step>. A transport rule after the
    measured server can delete them (header exists), so that no mailbox grows. Plain SMTP by default,
    STARTTLS with -StartTls (certificate not checked: lab use). Windows PowerShell 5.1 or PowerShell 7.

    Rate limit: the receive connectors of Exchange limit the messages per minute of one sending host
    (MessageRateLimit, MessageRateSource IPAddress). On an Edge Transport server the default connector
    "Default internal Receive connector <server>" accepts 600 messages per minute, that is 10 messages/s:
    above it, Exchange answers 4.4.2 and the step stays near 10 messages/s. Before the steps above
    10 messages/s, raise the limit for the duration of the calibration (dedicated receive connector limited
    to the address of this computer, or Set-ReceiveConnector -MessageRateLimit Unlimited), then restore it.
    Replies 4.4.2 are counted apart (Throttled) and reported.

.PARAMETER SmtpServer
    Server to load (name or address), port -Port (25).

.PARAMETER From
    Sender of the messages.

.PARAMETER To
    Recipients of every message (an accepted domain of the measured server).

.PARAMETER Rates
    Messages per second, one step per rate.

.PARAMETER StepSeconds
    Duration of each step. Use the duration of the Measure-TransportLoad.ps1 step.

.PARAMETER Connections
    SMTP sessions in parallel. Default: one per 4 messages/s (at least 1, at most 16). Each session waits for
    the acknowledgement of every message: on an Edge with the antispam agents (DNS lookups of Sender ID and
    sender reputation) and the relay to the Mailbox servers, about 1.5 s in the lab. When the rate reached
    stays below the rate asked, use more sessions (lab: 40 sessions for 20 messages/s).

.PARAMETER MessageSizeKB
    Size of the plain text body.

.PARAMETER AttachmentKB
    Size of the attachment of a message (file size, before the base64 encoding that adds about 37 %), 0 for
    no attachment. Several sizes with -AttachmentWeight make a mix: each message draws one of them.

.PARAMETER AttachmentWeight
    Weight of each size of -AttachmentKB (same count). Default: the same weight for all.

.PARAMETER MessagesPerSession
    Messages sent in one SMTP session before QUIT and a new session (new TCP connection, EHLO and, with
    -StartTls, a new TLS negotiation). 0 (default): the session stays open. Internet senders open about one
    session per message.

.EXAMPLE
    .\Send-TransportTestLoad.ps1 -SmtpServer ref-edge.dmz.lab -From calib@contoso.com -To calib@contoso.com -Rates 2,5,10,20 -StepSeconds 660

.EXAMPLE
    .\Send-TransportTestLoad.ps1 -SmtpServer ref-edge.dmz.lab -From calib@contoso.com -To calib@contoso.com -Rates 20 -Count 20000 -Label backlog

.EXAMPLE
    .\Send-TransportTestLoad.ps1 -SmtpServer ref-edge.dmz.lab -From calib@contoso.com -To calib@contoso.com -Rates 10 -MessageSizeKB 20 -AttachmentKB 0,250,2000 -AttachmentWeight 70,25,5 -MessagesPerSession 1 -StartTls -Connections 40
    A mix of sizes, one TLS session per message.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.9.0
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SmtpServer,
    [ValidateRange(1, 65535)][int]$Port = 25,
    [Parameter(Mandatory = $true)][string]$From,
    [Parameter(Mandatory = $true)][string[]]$To,
    [ValidateCount(1, 50)][double[]]$Rates = @(2, 5, 10, 20),
    [ValidateRange(1, 86400)][int]$StepSeconds = 600,
    [ValidateRange(0, 3600)][int]$PauseSeconds = 60,
    [ValidateRange(1, 51200)][int]$MessageSizeKB = 75,
    [ValidateRange(0, 51200)][int[]]$AttachmentKB = @(0),
    [double[]]$AttachmentWeight,
    [ValidateRange(0, 100000)][int]$MessagesPerSession = 0,
    [ValidateRange(0, 10000000)][int]$Count = 0,
    [ValidateRange(0, 256)][int]$Connections = 0,
    [switch]$StartTls,
    [string]$HeloName = [Net.Dns]::GetHostName(),
    [ValidatePattern('^[\w\-.]*$')][string]$Label = '',
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($LogPath) { $LogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath) }

function New-TslBody {
    <#
        Plain text body of about SizeKB: ordinary business sentences (ASCII), wrapped at 76 characters, so that
        the antispam agents of an Edge server process it like a normal message. No line starts with a dot.
    #>
    param([int]$SizeKB)
    $sentences = @(
        'Please find below the summary of the meeting held this morning with the project team.'
        'The delivery of the new version is planned for the end of the month, after the final tests.'
        'We reviewed the open points and agreed on the next steps for each workstream.'
        'The budget remains within the limits approved by the steering committee last quarter.'
        'Could you confirm your availability for a short call on Thursday afternoon?'
        'The training sessions for the support team will start next week in both offices.'
        'All servers were patched during the maintenance window without any incident.'
        'The customer asked for an updated schedule and a list of the remaining tasks.'
        'Thank you for your feedback on the document, the comments have been integrated.'
        'The quarterly report will be shared with the management team on Monday.'
        'Several users reported slow access to the shared folders, the network team is checking.'
        'The contract renewal is under review by the legal department and should be signed soon.'
        'We will keep you informed of any change in the planning or in the scope of the project.'
        'The migration of the remaining mailboxes is scheduled over the next two weekends.'
        'Best regards and have a good day.'
    )
    $random = [Random]::new(42)
    $builder = [Text.StringBuilder]::new($SizeKB * 1024 + 256)
    $line = [Text.StringBuilder]::new(80)
    while ($builder.Length -lt $SizeKB * 1024 - 1200) {
        foreach ($word in ($sentences[$random.Next($sentences.Count)] -split ' ')) {
            if ($line.Length + $word.Length + 1 -gt 76) { [void]$builder.Append($line.ToString()).Append("`r`n"); [void]$line.Clear() }
            if ($line.Length -gt 0) { [void]$line.Append(' ') }
            [void]$line.Append($word)
        }
        if ($random.Next(6) -eq 0) { [void]$builder.Append($line.ToString()).Append("`r`n`r`n"); [void]$line.Clear() }
    }
    if ($line.Length -gt 0) { [void]$builder.Append($line.ToString()).Append("`r`n") }
    return $builder.ToString()
}

function New-TslContent {
    <#
        MIME part of a message, from MIME-Version to the end: the text body alone, or the text body and an
        attachment of AttachmentKB (random bytes behind a PDF signature, base64 in lines of 76 characters).
    #>
    param([string]$Body, [int]$AttachmentKB, [int]$Index)
    if ($AttachmentKB -le 0) { return "MIME-Version: 1.0`r`nContent-Type: text/plain; charset=us-ascii`r`n`r`n" + $Body }
    $bytes = [byte[]]::new($AttachmentKB * 1024)
    [Random]::new(1000 + $Index).NextBytes($bytes)
    $signature = [Text.Encoding]::ASCII.GetBytes("%PDF-1.7`n")
    [Array]::Copy($signature, $bytes, [Math]::Min($signature.Length, $bytes.Length))
    $encoded = [Convert]::ToBase64String($bytes, [Base64FormattingOptions]::InsertLineBreaks)
    $boundary = '=_TransportSizer_{0}' -f $Index
    $name = 'Report-{0}KB.pdf' -f $AttachmentKB
    return "MIME-Version: 1.0`r`nContent-Type: multipart/mixed; boundary=`"$boundary`"`r`n`r`n--$boundary`r`nContent-Type: text/plain; charset=us-ascii`r`nContent-Transfer-Encoding: 7bit`r`n`r`n" +
    $Body + "`r`n--$boundary`r`nContent-Type: application/pdf; name=`"$name`"`r`nContent-Disposition: attachment; filename=`"$name`"`r`nContent-Transfer-Encoding: base64`r`n`r`n" +
    $encoded + "`r`n--$boundary--`r`n"
}

$worker = {
    param($Server, $Port, $From, $To, $Interval, $Until, $Quota, $Contents, $Cumulative, $PerSession, $Helo, $StartTls, $Step, $WorkerId, $Shared)

    $ErrorActionPreference = 'Stop'
    $conn = @{ Client = $null; Reader = $null; Writer = $null; InSession = 0; Opened = 0 }
    function Read-SmtpReply {
        $last = $null
        do {
            $line = $conn.Reader.ReadLine()
            if ($null -eq $line) { throw 'connexion fermée par le serveur' }
            $last = $line
        } while ($line.Length -ge 4 -and $line[3] -eq '-')
        return $last
    }
    function Invoke-Smtp([string]$Command, [string]$Expect) {
        if ($Command) { $conn.Writer.Write($Command + "`r`n"); $conn.Writer.Flush() }
        $reply = Read-SmtpReply
        if (-not $reply.StartsWith($Expect)) { throw "$Command -> $reply" }
    }
    function Open-Smtp {
        $conn.Client = [Net.Sockets.TcpClient]::new()
        $conn.Client.Connect($Server, $Port)
        $conn.Client.ReceiveTimeout = 60000
        $conn.InSession = 0
        $conn.Opened++
        $stream = $conn.Client.GetStream()
        $conn.Reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII)
        $conn.Writer = [IO.StreamWriter]::new($stream, [Text.Encoding]::ASCII)
        Invoke-Smtp '' '220'
        Invoke-Smtp "EHLO $Helo" '250'
        if ($StartTls) {
            Invoke-Smtp 'STARTTLS' '220'
            $ssl = [Net.Security.SslStream]::new($stream, $false, [Net.Security.RemoteCertificateValidationCallback] { $true })
            $ssl.AuthenticateAsClient($Server)
            $conn.Reader = [IO.StreamReader]::new($ssl, [Text.Encoding]::ASCII)
            $conn.Writer = [IO.StreamWriter]::new($ssl, [Text.Encoding]::ASCII)
            Invoke-Smtp "EHLO $Helo" '250'
        }
    }

    $sent = 0; $failed = 0; $throttled = 0; $reconnects = 0; $bytes = [long]0; $errors = @()
    $random = [Random]::new($WorkerId * 7919)
    $next = [DateTime]::UtcNow
    while ([DateTime]::UtcNow -lt $Until -and ($Quota -le 0 -or $sent -lt $Quota) -and -not $Shared.Stop) {
        $wait = ($next - [DateTime]::UtcNow).TotalMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min($wait, 1000.0)); continue }
        $next = $next.AddMilliseconds($Interval)
        if ($next -lt [DateTime]::UtcNow.AddSeconds(-2)) { $next = [DateTime]::UtcNow }
        $draw = $random.NextDouble() * $Cumulative[$Cumulative.Count - 1]
        $pick = 0
        while ($pick -lt $Cumulative.Count - 1 -and $draw -ge $Cumulative[$pick]) { $pick++ }
        try {
            if (-not $conn.Client -or -not $conn.Client.Connected) { Open-Smtp }
            Invoke-Smtp "MAIL FROM:<$From>" '250'
            foreach ($rcpt in $To) { Invoke-Smtp "RCPT TO:<$rcpt>" '250' }
            Invoke-Smtp 'DATA' '354'
            $id = [Guid]::NewGuid().ToString('N')
            $headers = "From: <$From>`r`nTo: " + (($To | ForEach-Object { "<$_>" }) -join ', ') + "`r`nSubject: Transport Sizer calibration $Step #$WorkerId-$sent`r`n" +
            "Date: $([DateTime]::UtcNow.ToString('r'))`r`nMessage-ID: <$id@$Helo>`r`nX-TransportSizer-Calibration: $Step`r`n"
            $conn.Writer.Write($headers); $conn.Writer.Write($Contents[$pick]); $conn.Writer.Write("`r`n.`r`n"); $conn.Writer.Flush()
            Invoke-Smtp '' '250'
            $sent++
            $bytes += $headers.Length + $Contents[$pick].Length
            $conn.InSession++
            if ($PerSession -gt 0 -and $conn.InSession -ge $PerSession) {
                try { Invoke-Smtp 'QUIT' '221' } catch { }
                try { $conn.Client.Close() } catch { }
                $conn.Client = $null
            }
            else { Invoke-Smtp 'RSET' '250' }
        }
        catch {
            # 421 4.4.1 before a message (RSET, MAIL FROM): the server ended the session (ConnectionTimeout of
            # the receive connector, 5 minutes on an Edge). Nothing was being sent: reconnect, not a failure.
            if ($_.Exception.Message -match '^(RSET|MAIL FROM)\S* .*-> 421 ') { $reconnects++ }
            else {
                $failed++
                # 4.4.2: MessageRateLimit of the receive connector (one sending host), see the help.
                if ($_.Exception.Message -match '\b4\.4\.2\b') { $throttled++ }
                if ($errors.Count -lt 5) { $errors += $_.Exception.Message }
                Start-Sleep -Milliseconds 500
            }
            try { if ($conn.Client) { $conn.Client.Close() } } catch { }
            $conn.Client = $null
        }
    }
    try { if ($conn.Client -and $conn.Client.Connected) { $conn.Writer.Write("QUIT`r`n"); $conn.Writer.Flush(); $conn.Client.Close() } } catch { }
    [pscustomobject]@{ Worker = $WorkerId; Sent = $sent; Failed = $failed; Throttled = $throttled; Reconnects = $reconnects; Bytes = $bytes; Sessions = $conn.Opened; Errors = $errors }
}

if ($null -eq $AttachmentWeight -or $AttachmentWeight.Count -eq 0) { $AttachmentWeight = @(foreach ($a in $AttachmentKB) { 1.0 }) }
if ($AttachmentWeight.Count -ne $AttachmentKB.Count) { throw '-AttachmentWeight doit avoir autant de valeurs que -AttachmentKB.' }
if (@($AttachmentWeight | Where-Object { $_ -lt 0 }).Count -gt 0 -or ($AttachmentWeight | Measure-Object -Sum).Sum -le 0) { throw 'Les poids -AttachmentWeight doivent être positifs.' }
$body = New-TslBody -SizeKB $MessageSizeKB
$contents = [string[]]@(for ($i = 0; $i -lt $AttachmentKB.Count; $i++) { New-TslContent -Body $body -AttachmentKB $AttachmentKB[$i] -Index $i })
$cumulative = [double[]]::new($AttachmentKB.Count)
$total = 0.0
for ($i = 0; $i -lt $AttachmentKB.Count; $i++) { $total += $AttachmentWeight[$i]; $cumulative[$i] = $total }
$expectedKB = 0.0
for ($i = 0; $i -lt $AttachmentKB.Count; $i++) { $expectedKB += $AttachmentWeight[$i] / $total * ($contents[$i].Length + 250) / 1024 }
$mix = if ($AttachmentKB.Count -eq 1 -and $AttachmentKB[0] -eq 0) { 'sans pièce jointe' } else { 'pièces jointes ' + (@(for ($i = 0; $i -lt $AttachmentKB.Count; $i++) { '{0} Ko × {1}' -f $AttachmentKB[$i], $AttachmentWeight[$i] }) -join ', ') }
$log = [Collections.Generic.List[object]]::new()
$shared = [hashtable]::Synchronized(@{ Stop = $false })
$index = 0
foreach ($rate in $Rates) {
    $index++
    if ($rate -le 0) { throw 'Chaque débit doit être positif.' }
    $sessions = $Connections
    if ($sessions -le 0) { $sessions = [int][Math]::Min(16.0, [Math]::Max(1.0, [Math]::Ceiling($rate / 4))) }
    $step = if ($Label) { $Label } else { 'load-{0}' -f ($rate.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)) }
    $interval = 1000.0 * $sessions / $rate
    $quota = 0
    if ($Count -gt 0) { $quota = [int][Math]::Ceiling($Count / $sessions) }
    $start = [DateTime]::UtcNow
    $until = if ($Count -gt 0) { $start.AddDays(1) } else { $start.AddSeconds($StepSeconds) }
    Write-Host ('[{0:HH:mm:ss}] Palier {1} : {2} msg/s vers {3}:{4}, {5} session(s){6}{7}, {8} Ko de texte, {9} (≈ {10} Ko par message){11}' -f (Get-Date), $step, $rate, $SmtpServer, $Port, $sessions,
        $(if ($MessagesPerSession -gt 0) { " de $MessagesPerSession message(s)" } else { '' }), $(if ($StartTls) { ' TLS' } else { '' }), $MessageSizeKB, $mix, [Math]::Round($expectedKB, 0),
        $(if ($Count -gt 0) { ", $Count messages" } else { ", $StepSeconds s" }))
    $pool = [RunspaceFactory]::CreateRunspacePool(1, $sessions)
    $pool.Open()
    $jobs = @()
    try {
        for ($w = 1; $w -le $sessions; $w++) {
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($worker).AddArgument($SmtpServer).AddArgument($Port).AddArgument($From).AddArgument([string[]]$To).AddArgument($interval).AddArgument($until).AddArgument($quota).
                AddArgument($contents).AddArgument($cumulative).AddArgument($MessagesPerSession).AddArgument($HeloName).AddArgument([bool]$StartTls).AddArgument($step).AddArgument($w).AddArgument($shared)
            $jobs += [pscustomobject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke() }
        }
        $results = foreach ($job in $jobs) { $job.PowerShell.EndInvoke($job.Handle); $job.PowerShell.Dispose() }
    }
    finally { $pool.Close(); $pool.Dispose() }
    $end = [DateTime]::UtcNow
    $sent = ($results | Measure-Object -Property Sent -Sum).Sum
    $failed = ($results | Measure-Object -Property Failed -Sum).Sum
    $throttled = ($results | Measure-Object -Property Throttled -Sum).Sum
    $seconds = ($end - $start).TotalSeconds
    $reconnects = ($results | Measure-Object -Property Reconnects -Sum).Sum
    $bytes = [double]($results | Measure-Object -Property Bytes -Sum).Sum
    $opened = ($results | Measure-Object -Property Sessions -Sum).Sum
    $entry = [pscustomobject]@{
        Step = $step; Rate = $rate; Sessions = $sessions; MessageSizeKB = $MessageSizeKB; AttachmentKB = @($AttachmentKB); AttachmentWeight = @($AttachmentWeight)
        AverageKB = $(if ($sent -gt 0) { [Math]::Round($bytes / $sent / 1024, 1) } else { 0 }); MessagesPerSession = $MessagesPerSession; StartTls = [bool]$StartTls; SessionsOpened = $opened
        StartUtc = $start.ToString('o'); EndUtc = $end.ToString('o')
        Seconds = [Math]::Round($seconds, 1); Sent = $sent; Failed = $failed; Throttled = $throttled; Reconnects = $reconnects; Achieved = [Math]::Round($sent / [Math]::Max(1.0, $seconds), 3)
        Errors = @($results | ForEach-Object { $_.Errors } | Select-Object -Unique -First 5)
    }
    $log.Add($entry)
    $color = if ($failed -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host ('[{0:HH:mm:ss}] {1} : {2} envoyés, {3} échecs, {4} msg/s atteints, {5} Ko par message, {6} session(s) ouvertes' -f (Get-Date), $step, $sent, $failed, $entry.Achieved, $entry.AverageKB, $opened) -ForegroundColor $color
    if ($throttled -gt 0) {
        Write-Host ('    {0} refus 4.4.2 : limite MessageRateLimit du connecteur de réception pour cette adresse (600 messages/min sur le connecteur par défaut d’’un Edge). Relever la limite pendant la calibration.' -f $throttled) -ForegroundColor Yellow
    }
    foreach ($message in $entry.Errors) { Write-Host "    $message" -ForegroundColor Yellow }
    if ($Count -gt 0) { break }
    if ($index -lt $Rates.Count -and $PauseSeconds -gt 0) { Start-Sleep -Seconds $PauseSeconds }
}
if ($LogPath) { [IO.File]::WriteAllText($LogPath, (ConvertTo-Json -InputObject @($log) -Depth 4), [Text.UTF8Encoding]::new($false)) }
$log
