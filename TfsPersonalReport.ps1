<#
.SYNOPSIS
    Erzeugt eine optisch aufbereitete Personalauswertung (HTML-Dashboard) aus
    einem lokalen TFS / Azure DevOps Server.

.DESCRIPTION
    Holt ueber die REST-API:
      * Work Items (Aufgaben), die dir zugeordnet sind/waren, der letzten N Monate
      * TFVC-Changesets (Check-ins), die du committet hast

    und berechnet Kennzahlen fuer dein Personalgespraech:
      1. Geplant vs. tatsaechlich  (OriginalEstimate vs. CompletedWork, Schaetzgenauigkeit)
      2. Termintreue & Durchlaufzeit (Cycle Time)
      3. Volumen & Typen           (Anzahl, nach Typ/Prioritaet/Monat)
      4. Code-Aktivitaet aus TFVC  (Changesets, geaenderte Dateien)

    Ergebnis: eine eigenstaendige HTML-Datei (Inline-SVG-Diagramme, kein Internet
    noetig), die sich im Browser oeffnen und als PDF drucken laesst.

.PARAMETER CollectionUrl
    Basis-URL der TFS-Collection, z.B. http://tfs-server:8080/tfs/DefaultCollection
    oder https://devops.firma.local/DefaultCollection

.PARAMETER Project
    Name des Team-Projekts (wie in TFS angezeigt).

.PARAMETER Months
    Auswertungszeitraum in Monaten rueckwirkend. Standard: 12.

.PARAMETER Pat
    Optionaler Personal Access Token. Ohne Angabe wird der angemeldete
    Windows-Benutzer verwendet (integrierte Authentifizierung / NTLM).

.PARAMETER TfvcAuthor
    Autor-Kennung fuer die Changeset-Suche, z.B. DOMAENE\benutzer.
    Standard: aktueller Windows-Benutzer.

.PARAMETER ApiVersion
    REST-API-Version. Standard 5.0. Bei sehr alten Servern ggf. auf 3.0 / 2.0
    senken (TFS 2015 = 2.x, 2017 = 3.x, 2018 = 4.x, DevOps Server 2019+ = 5.x).

.PARAMETER IncludeChangesetFiles
    Holt pro Changeset die Anzahl geaenderter Dateien (zusaetzliche API-Aufrufe,
    langsamer, dafuer detaillierter).

.PARAMETER SkipCertCheck
    Ignoriert Zertifikatsfehler (selbstsigniertes HTTPS im Firmennetz).

.PARAMETER Demo
    Nutzt Beispieldaten statt des echten Servers - zum Ansehen des Reports.

.PARAMETER Open
    Oeffnet den fertigen Report automatisch im Standardbrowser.

.EXAMPLE
    # Erst mal nur ansehen, wie der Report aussieht:
    .\TfsPersonalReport.ps1 -Demo -Open

.EXAMPLE
    # Echte Auswertung mit angemeldetem Windows-Benutzer:
    .\TfsPersonalReport.ps1 -CollectionUrl "http://tfs:8080/tfs/DefaultCollection" -Project "MeinProjekt" -Open

.EXAMPLE
    # Mit Personal Access Token und HTTPS (selbstsigniert):
    .\TfsPersonalReport.ps1 -CollectionUrl "https://devops.firma.local/DefaultCollection" -Project "MeinProjekt" -Pat $env:TFS_PAT -SkipCertCheck -IncludeChangesetFiles -Open
#>

[CmdletBinding()]
param(
    [string]$CollectionUrl,
    [string]$Project,
    [int]$Months = 12,
    [string]$Pat,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$TfvcAuthor,
    [string]$Name,
    [string]$AssignedTo = '@Me',
    [hashtable[]]$Developers,
    [switch]$Compare,
    [double]$FteHours = 40,
    [string]$ApiVersion = '5.0',
    [string]$OutFile,
    [switch]$IncludeChangesetFiles,
    [switch]$SkipCertCheck,
    [switch]$Demo,
    [switch]$Open
)

$ErrorActionPreference = 'Stop'
$deDE = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
$inv  = [System.Globalization.CultureInfo]::InvariantCulture  # fuer SVG-Koordinaten (Dezimalpunkt!)

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

function fmt {
    param([double]$Value, [int]$Decimals = 1)
    return $Value.ToString("N$Decimals", $deDE)
}

function Format-Metric {
    param([double]$Value, [string]$Type)
    if ($Type -eq 'int') { return [string][int][math]::Round($Value) }
    elseif ($Type -eq 'h') { return "$(fmt $Value 0) h" }
    else { return "$(fmt $Value 0) %" }
}

function Esc {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

function Get-MonthList {
    param([int]$Count)
    $now = Get-Date
    $list = @()
    for ($i = $Count - 1; $i -ge 0; $i--) {
        $d = $now.AddMonths(-$i)
        $list += [pscustomobject]@{
            Key   = $d.ToString('yyyy-MM')
            Label = $d.ToString('MMM yy', $deDE)
        }
    }
    return $list
}

# ---------------------------------------------------------------------------
# TFS REST-Aufruf
# ---------------------------------------------------------------------------

function Invoke-Tfs {
    param(
        [string]$Url,
        [string]$Method = 'GET',
        $Body
    )
    # Leerzeichen in Collection-/Projektnamen URL-sicher machen
    $Url = $Url -replace ' ', '%20'
    $headers = @{}
    if ($Credential) {
        # Windows-/Firmen-Konto: DOMAIN\user : passwort  -> Basic
        $plain = $Credential.GetNetworkCredential()
        $pair = "$($Credential.UserName):$($plain.Password)"
        $headers['Authorization'] = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    }
    elseif ($Pat) {
        # PAT  -> ":token"  |  Benutzer:Passwort -> "user:pass" (enthaelt bereits ':')
        $cred = if ($Pat -match ':') { $Pat } else { ":$Pat" }
        $token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cred))
        $headers['Authorization'] = "Basic $token"
    }
    $params = @{
        Uri         = $Url
        Method      = $Method
        Headers     = $headers
        ContentType = 'application/json'
        ErrorAction = 'Stop'
    }
    if (-not $Pat -and -not $Credential) { $params['UseDefaultCredentials'] = $true }
    if ($Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 6) }
    return Invoke-RestMethod @params
}

# ---------------------------------------------------------------------------
# Daten laden: Work Items
# ---------------------------------------------------------------------------

function Get-WorkItemData {
    param([string]$Base, [string]$Proj, [int]$Days, [string]$ApiVer, [string]$AssignedTo = '@Me')

    # @Me unquoted; konkrete Person in Hochkommas (Anzeigename oder DOMAIN\konto)
    $cond = if (-not $AssignedTo -or $AssignedTo -eq '@Me') { '@Me' } else { "'" + ($AssignedTo -replace "'", "''") + "'" }
    $wiql = "SELECT [System.Id] FROM WorkItems " +
            "WHERE [System.AssignedTo] = $cond AND [System.ChangedDate] >= @Today - $Days " +
            "ORDER BY [System.ChangedDate] DESC"

    # Mit Projekt -> nur dieses Projekt; ohne Projekt -> gesamte Collection (alle Kundenprojekte)
    if ($Proj) {
        $wiqlUrl = "$Base/$Proj/_apis/wit/wiql?api-version=$ApiVer"
        Write-Host "  -> WIQL-Abfrage (Projekt '$Proj')..." -ForegroundColor DarkGray
    } else {
        $wiqlUrl = "$Base/_apis/wit/wiql?api-version=$ApiVer"
        Write-Host "  -> WIQL-Abfrage (gesamte Collection)..." -ForegroundColor DarkGray
    }
    $res = Invoke-Tfs -Url $wiqlUrl -Method POST -Body @{ query = $wiql }
    $ids = @($res.workItems.id)
    Write-Host "     $($ids.Count) Aufgaben gefunden." -ForegroundColor DarkGray
    if ($ids.Count -eq 0) { return @() }

    $fields = @(
        'System.Id','System.Title','System.WorkItemType','System.State',
        'System.CreatedDate','System.ChangedDate',
        'Microsoft.VSTS.Scheduling.OriginalEstimate',
        'Microsoft.VSTS.Scheduling.CompletedWork',
        'Microsoft.VSTS.Scheduling.RemainingWork',
        'Microsoft.VSTS.Scheduling.DueDate',
        'Microsoft.VSTS.Common.Priority',
        'Microsoft.VSTS.Common.ClosedDate',
        'Microsoft.VSTS.Common.ResolvedDate',
        'Microsoft.VSTS.Common.StateChangeDate',
        'System.TeamProject','System.IterationPath','System.AreaPath'
    ) -join ','

    $items = @()
    for ($i = 0; $i -lt $ids.Count; $i += 200) {
        $end = [math]::Min($i + 199, $ids.Count - 1)
        $chunk = ($ids[$i..$end]) -join ','
        $wi = Invoke-Tfs -Url "$Base/_apis/wit/workitems?ids=$chunk&fields=$fields&api-version=$ApiVer"
        foreach ($w in $wi.value) {
            $f = $w.fields
            $items += [pscustomobject]@{
                Id        = $w.id
                Title     = $f.'System.Title'
                Type      = $f.'System.WorkItemType'
                State     = $f.'System.State'
                Created   = if ($f.'System.CreatedDate') { [datetime]$f.'System.CreatedDate' } else { $null }
                Changed   = if ($f.'System.ChangedDate') { [datetime]$f.'System.ChangedDate' } else { $null }
                Closed    = if ($f.'Microsoft.VSTS.Common.ClosedDate') { [datetime]$f.'Microsoft.VSTS.Common.ClosedDate' }
                            elseif ($f.'Microsoft.VSTS.Common.ResolvedDate') { [datetime]$f.'Microsoft.VSTS.Common.ResolvedDate' }
                            elseif ($f.'Microsoft.VSTS.Common.StateChangeDate') { [datetime]$f.'Microsoft.VSTS.Common.StateChangeDate' }
                            else { $null }
                Due       = if ($f.'Microsoft.VSTS.Scheduling.DueDate') { [datetime]$f.'Microsoft.VSTS.Scheduling.DueDate' } else { $null }
                Original  = [double]($f.'Microsoft.VSTS.Scheduling.OriginalEstimate')
                Completed = [double]($f.'Microsoft.VSTS.Scheduling.CompletedWork')
                Remaining = [double]($f.'Microsoft.VSTS.Scheduling.RemainingWork')
                Priority  = $f.'Microsoft.VSTS.Common.Priority'
                Project   = $f.'System.TeamProject'
                Iteration = $f.'System.IterationPath'
                Area      = $f.'System.AreaPath'
            }
        }
    }
    return $items
}

# ---------------------------------------------------------------------------
# Daten laden: TFVC-Changesets
# ---------------------------------------------------------------------------

function Get-ChangesetData {
    param([string]$Base, [string]$Author, [datetime]$From, [datetime]$To, [string]$ApiVer, [bool]$WithFiles)

    $fromS = $From.ToString('yyyy-MM-dd')
    $toS   = $To.ToString('yyyy-MM-dd')
    $authorEnc = [uri]::EscapeDataString($Author)
    $url = "$Base/_apis/tfvc/changesets?searchCriteria.author=$authorEnc&searchCriteria.fromDate=$fromS&searchCriteria.toDate=$toS&" + '$top=10000' + "&api-version=$ApiVer"

    Write-Host "  -> Changesets von '$Author'..." -ForegroundColor DarkGray
    $res = Invoke-Tfs -Url $url
    $list = @()
    foreach ($c in $res.value) {
        $files = $null
        if ($WithFiles) {
            try {
                $ch = Invoke-Tfs -Url "$Base/_apis/tfvc/changesets/$($c.changesetId)/changes?api-version=$ApiVer"
                $files = if ($ch.count) { [int]$ch.count } else { @($ch.value).Count }
            } catch { $files = $null }
        }
        $list += [pscustomobject]@{
            Id      = $c.changesetId
            Date    = [datetime]$c.createdDate
            Comment = $c.comment
            Files   = $files
        }
    }
    Write-Host "     $($list.Count) Changesets gefunden." -ForegroundColor DarkGray
    return $list
}

# ---------------------------------------------------------------------------
# Demo-Daten
# ---------------------------------------------------------------------------

function New-DemoWorkItems {
    param([int]$Months, [int]$Seed = 20260614)
    $rnd = [System.Random]::new($Seed)
    $types = @('Task','Bug','Feature','User Story')
    $typeWeights = @('Task','Task','Task','Bug','Bug','Feature','User Story')
    $items = @()
    $id = 41200
    for ($m = $Months - 1; $m -ge 0; $m--) {
        $count = $rnd.Next(2, 7)
        for ($k = 0; $k -lt $count; $k++) {
            $created = (Get-Date).AddMonths(-$m).AddDays($rnd.Next(0, 25)).AddHours(-$rnd.Next(0, 200))
            $type = $typeWeights[$rnd.Next(0, $typeWeights.Count)]
            $orig = [math]::Round(($rnd.Next(2, 40) + $rnd.NextDouble()), 1)
            # tatsaechlich: meist nah dran, manchmal drueber/drunter
            $factor = 0.7 + $rnd.NextDouble() * 0.8
            $comp = [math]::Round($orig * $factor, 1)
            $cycle = $rnd.Next(1, 25)
            $closed = $created.AddDays($cycle).AddHours($rnd.Next(0, 8))
            $isOpen = ($m -eq 0 -and $rnd.NextDouble() -lt 0.4)
            $due = $created.AddDays($rnd.Next(5, 20))
            $id++
            $items += [pscustomobject]@{
                Id        = $id
                Title     = "$type #$id - Beispielaufgabe im Modul " + @('Auftrag','Lager','Buchhaltung','Reporting','UI','Schnittstelle')[$rnd.Next(0,6)]
                Type      = $type
                State     = if ($isOpen) { 'Active' } else { @('Closed','Done','Resolved')[$rnd.Next(0,3)] }
                Created   = $created
                Changed   = if ($isOpen) { Get-Date } else { $closed }
                Closed    = if ($isOpen) { $null } else { $closed }
                Due       = $due
                Original  = $orig
                Completed = if ($isOpen) { [math]::Round($comp * 0.5, 1) } else { $comp }
                Remaining = if ($isOpen) { [math]::Round($orig * 0.5, 1) } else { 0 }
                Priority  = $rnd.Next(1, 5)
                Project   = @('eEvolution 6','eEvolution Mobile','Mustermann GmbH','Beispiel AG','Demo Kunde KG')[$rnd.Next(0,5)]
                Iteration = "Sprint $($rnd.Next(40,60))"
                Area      = 'eEvolution\' + @('Kern','Module','Schnittstellen')[$rnd.Next(0,3)]
            }
        }
    }
    return $items
}

function New-DemoChangesets {
    param([int]$Months, [int]$Seed = 7)
    $rnd = [System.Random]::new($Seed)
    $list = @()
    $id = 88100
    for ($m = $Months - 1; $m -ge 0; $m--) {
        $count = $rnd.Next(4, 20)
        for ($k = 0; $k -lt $count; $k++) {
            $id++
            $list += [pscustomobject]@{
                Id      = $id
                Date    = (Get-Date).AddMonths(-$m).AddDays($rnd.Next(0, 27))
                Comment = 'Fix/Feature commit'
                Files   = $rnd.Next(1, 15)
            }
        }
    }
    return $list
}

# ---------------------------------------------------------------------------
# SVG-Diagramme (Inline, ohne externe Abhaengigkeiten)
# ---------------------------------------------------------------------------

function Get-NiceMax {
    param([double]$Max)
    if ($Max -le 0) { return 1 }
    $exp = [math]::Floor([math]::Log10($Max))
    $base = [math]::Pow(10, $exp)
    $n = [math]::Ceiling($Max / $base)
    if ($n -le 1) { $n = 1 } elseif ($n -le 2) { $n = 2 } elseif ($n -le 5) { $n = 5 } else { $n = 10 }
    return $n * $base
}

function New-GroupedBarChart {
    param([string[]]$Labels, [double[]]$A, [double[]]$B, [string]$NameA, [string]$NameB,
          [string]$ColorA = '#2563eb', [string]$ColorB = '#f59e0b')
    if (-not $Labels -or $Labels.Count -eq 0) { return '<p class="empty">Keine Daten.</p>' }
    $w = 860; $h = 320; $padL = 44; $padR = 14; $padT = 14; $padB = 52
    $plotW = $w - $padL - $padR; $plotH = $h - $padT - $padB
    $all = @($A + $B)
    $max = Get-NiceMax (($all | Measure-Object -Maximum).Maximum)
    $n = $Labels.Count
    $groupW = $plotW / $n
    $barW = [math]::Min(26, ($groupW - 8) / 2)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<svg viewBox='0 0 $w $h' class='chart' preserveAspectRatio='xMidYMid meet'>")
    # Gitterlinien + Y-Achse
    for ($g = 0; $g -le 4; $g++) {
        $yv = $max * $g / 4
        $y = $padT + $plotH - ($plotH * $g / 4)
        [void]$sb.Append("<line x1='$padL' y1='$y' x2='$($padL+$plotW)' y2='$y' class='grid'/>")
        [void]$sb.Append("<text x='$($padL-6)' y='$($y+4)' class=' axlbl' text-anchor='end'>$([int]$yv)</text>")
    }
    for ($i = 0; $i -lt $n; $i++) {
        $gx = $padL + $i * $groupW
        $cx = $gx + $groupW / 2
        $hA = if ($max -gt 0) { $plotH * $A[$i] / $max } else { 0 }
        $hB = if ($max -gt 0) { $plotH * $B[$i] / $max } else { 0 }
        $xA = $cx - $barW - 2; $xB = $cx + 2
        $yA = $padT + $plotH - $hA; $yB = $padT + $plotH - $hB
        [void]$sb.Append("<rect x='$($xA.ToString('0.#',$inv))' y='$($yA.ToString('0.#',$inv))' width='$($barW.ToString('0.#',$inv))' height='$($hA.ToString('0.#',$inv))' rx='2' fill='$ColorA'><title>$($Labels[$i]) $NameA`: $(fmt $A[$i]) h</title></rect>")
        [void]$sb.Append("<rect x='$($xB.ToString('0.#',$inv))' y='$($yB.ToString('0.#',$inv))' width='$($barW.ToString('0.#',$inv))' height='$($hB.ToString('0.#',$inv))' rx='2' fill='$ColorB'><title>$($Labels[$i]) $NameB`: $(fmt $B[$i]) h</title></rect>")
        [void]$sb.Append("<text x='$($cx.ToString('0.#',$inv))' y='$($h-34)' class='axlbl' text-anchor='middle' transform='rotate(0)'>$($Labels[$i])</text>")
    }
    [void]$sb.Append("</svg>")
    $legend = "<div class='legend'><span><i style='background:$ColorA'></i>$NameA</span><span><i style='background:$ColorB'></i>$NameB</span></div>"
    return $sb.ToString() + $legend
}

function New-BarChart {
    param([string[]]$Labels, [double[]]$Values, [string]$Color = '#2563eb')
    if (-not $Labels -or $Labels.Count -eq 0) { return '<p class="empty">Keine Daten.</p>' }
    $n = $Labels.Count
    $maxLen = ($Labels | ForEach-Object { "$_".Length } | Measure-Object -Maximum).Maximum
    $rotate = ($n -gt 6) -or ($maxLen -gt 9)
    $w = 860; $padL = 44; $padR = 14; $padT = 14; $padB = if ($rotate) { 96 } else { 46 }
    $h = $padT + 230 + $padB
    $plotW = $w - $padL - $padR; $plotH = $h - $padT - $padB
    $max = Get-NiceMax (($Values | Measure-Object -Maximum).Maximum)
    $groupW = $plotW / $n
    $barW = [math]::Min(46, $groupW - 10)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<svg viewBox='0 0 $w $h' class='chart' preserveAspectRatio='xMidYMid meet'>")
    for ($g = 0; $g -le 4; $g++) {
        $yv = $max * $g / 4
        $y = $padT + $plotH - ($plotH * $g / 4)
        [void]$sb.Append("<line x1='$padL' y1='$y' x2='$($padL+$plotW)' y2='$y' class='grid'/>")
        [void]$sb.Append("<text x='$($padL-6)' y='$($y+4)' class='axlbl' text-anchor='end'>$([int]$yv)</text>")
    }
    $axisY = $padT + $plotH
    for ($i = 0; $i -lt $n; $i++) {
        $cx = $padL + $i * $groupW + $groupW / 2
        $bh = if ($max -gt 0) { $plotH * $Values[$i] / $max } else { 0 }
        $x = $cx - $barW / 2
        $y = $padT + $plotH - $bh
        $lbl = "$($Labels[$i])"
        if ($lbl.Length -gt 18) { $lbl = $lbl.Substring(0,17) + [char]0x2026 }
        $cxS = $cx.ToString('0.#',$inv)
        [void]$sb.Append("<rect x='$($x.ToString('0.#',$inv))' y='$($y.ToString('0.#',$inv))' width='$($barW.ToString('0.#',$inv))' height='$($bh.ToString('0.#',$inv))' rx='3' fill='$Color'><title>$(Esc $Labels[$i]): $(fmt $Values[$i])</title></rect>")
        [void]$sb.Append("<text x='$cxS' y='$($y-5)' class='barval' text-anchor='middle'>$([int]$Values[$i])</text>")
        if ($rotate) {
            [void]$sb.Append("<text x='$cxS' y='$($axisY+14)' class='axlbl' text-anchor='end' transform='rotate(-35 $cxS $($axisY+14))'>$(Esc $lbl)</text>")
        } else {
            [void]$sb.Append("<text x='$cxS' y='$($axisY+18)' class='axlbl' text-anchor='middle'>$(Esc $lbl)</text>")
        }
    }
    [void]$sb.Append("</svg>")
    return $sb.ToString()
}

function New-LineChart {
    param([string[]]$Labels, [double[]]$Values, [string]$Color = '#16a34a')
    if (-not $Labels -or $Labels.Count -eq 0) { return '<p class="empty">Keine Daten.</p>' }
    $w = 860; $h = 280; $padL = 44; $padR = 14; $padT = 14; $padB = 46
    $plotW = $w - $padL - $padR; $plotH = $h - $padT - $padB
    $max = Get-NiceMax (($Values | Measure-Object -Maximum).Maximum)
    $n = $Labels.Count
    $step = if ($n -gt 1) { $plotW / ($n - 1) } else { 0 }
    $pts = @()
    for ($i = 0; $i -lt $n; $i++) {
        $x = $padL + $i * $step
        $y = $padT + $plotH - $(if ($max -gt 0) { $plotH * $Values[$i] / $max } else { 0 })
        $pts += "$($x.ToString('0.#',$inv)),$($y.ToString('0.#',$inv))"
    }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<svg viewBox='0 0 $w $h' class='chart' preserveAspectRatio='xMidYMid meet'>")
    for ($g = 0; $g -le 4; $g++) {
        $yv = $max * $g / 4
        $y = $padT + $plotH - ($plotH * $g / 4)
        [void]$sb.Append("<line x1='$padL' y1='$y' x2='$($padL+$plotW)' y2='$y' class='grid'/>")
        [void]$sb.Append("<text x='$($padL-6)' y='$($y+4)' class='axlbl' text-anchor='end'>$([int]$yv)</text>")
    }
    $area = "$($padL),$($padT+$plotH) " + ($pts -join ' ') + " $($padL+($n-1)*$step),$($padT+$plotH)"
    [void]$sb.Append("<polygon points='$area' fill='$Color' opacity='0.12'/>")
    [void]$sb.Append("<polyline points='$($pts -join ' ')' fill='none' stroke='$Color' stroke-width='2.5'/>")
    for ($i = 0; $i -lt $n; $i++) {
        $coords = $pts[$i].Split(',')
        [void]$sb.Append("<circle cx='$($coords[0])' cy='$($coords[1])' r='3.5' fill='$Color'><title>$($Labels[$i]): $([int]$Values[$i])</title></circle>")
        [void]$sb.Append("<text x='$($coords[0])' y='$($h-28)' class='axlbl' text-anchor='middle'>$($Labels[$i])</text>")
    }
    [void]$sb.Append("</svg>")
    return $sb.ToString()
}

function New-Donut {
    param([double]$OnTime, [double]$Late, [string]$ColorOk = '#16a34a', [string]$ColorBad = '#dc2626')
    $total = $OnTime + $Late
    if ($total -le 0) { return '<p class="empty">Keine Daten.</p>' }
    $pct = [math]::Round(100 * $OnTime / $total)
    $r = 70; $cx = 110; $cy = 110; $circ = 2 * [math]::PI * $r
    $okLen = $circ * $OnTime / $total
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<svg viewBox='0 0 220 220' class='donut'>")
    [void]$sb.Append("<circle cx='$cx' cy='$cy' r='$r' fill='none' stroke='$ColorBad' stroke-width='26'/>")
    [void]$sb.Append("<circle cx='$cx' cy='$cy' r='$r' fill='none' stroke='$ColorOk' stroke-width='26' stroke-dasharray='$($okLen.ToString('0.#',$inv)) $($circ.ToString('0.#',$inv))' transform='rotate(-90 $cx $cy)'/>")
    [void]$sb.Append("<text x='$cx' y='$($cy-2)' class='donut-num' text-anchor='middle'>$pct%</text>")
    [void]$sb.Append("<text x='$cx' y='$($cy+20)' class='donut-sub' text-anchor='middle'>termintreu</text>")
    [void]$sb.Append("</svg>")
    $legend = "<div class='legend'><span><i style='background:$ColorOk'></i>p&#252;nktlich ($([int]$OnTime))</span><span><i style='background:$ColorBad'></i>versp&#228;tet ($([int]$Late))</span></div>"
    return $sb.ToString() + $legend
}

function Get-ReportCss {
    return @'
:root{
  --bg:#eef2f7; --card:#ffffff; --ink:#0f172a; --muted:#64748b; --line:#e2e8f0;
  --blue:#2563eb; --green:#16a34a; --amber:#f59e0b; --red:#dc2626; --violet:#7c3aed;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
  font-family:-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;line-height:1.5}
.wrap{max-width:1080px;margin:0 auto;padding:32px 24px 64px}
header.hero{background:linear-gradient(135deg,#1e3a8a,#2563eb);color:#fff;border-radius:18px;
  padding:28px 32px;box-shadow:0 10px 30px rgba(37,99,235,.25);margin-bottom:24px}
header.hero h1{margin:0 0 4px;font-size:26px;font-weight:700}
header.hero .meta{opacity:.9;font-size:14px}
header.hero .meta b{font-weight:600}
.kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin-bottom:28px}
.kpi{background:var(--card);border-radius:14px;padding:18px 18px 16px;box-shadow:0 1px 3px rgba(15,23,42,.08);
  border-top:3px solid var(--blue)}
.kpi.good{border-top-color:var(--green)} .kpi.warn{border-top-color:var(--amber)} .kpi.bad{border-top-color:var(--red)}
.kpi-val{font-size:26px;font-weight:700;letter-spacing:-.5px}
.kpi.good .kpi-val{color:var(--green)} .kpi.warn .kpi-val{color:#b45309} .kpi.bad .kpi-val{color:var(--red)}
.kpi-lbl{font-size:13px;font-weight:600;margin-top:2px}
.kpi-sub{font-size:12px;color:var(--muted);margin-top:3px}
section.card{background:var(--card);border-radius:16px;padding:22px 24px;margin-bottom:20px;
  box-shadow:0 1px 3px rgba(15,23,42,.08)}
section.card h2{margin:0 0 4px;font-size:18px}
section.card .desc{color:var(--muted);font-size:13px;margin:0 0 16px}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:20px}
.split{display:grid;grid-template-columns:240px 1fr;gap:24px;align-items:center}
.chart{width:100%;height:auto}
.grid{stroke:var(--line);stroke-width:1}
.axlbl{fill:var(--muted);font-size:11px}
.barval{fill:var(--ink);font-size:11px;font-weight:600}
.donut{width:200px;height:200px}
.donut-num{font-size:34px;font-weight:700;fill:var(--ink)}
.donut-sub{font-size:12px;fill:var(--muted)}
.legend{display:flex;gap:18px;justify-content:center;margin-top:10px;font-size:13px;color:var(--muted)}
.legend i{display:inline-block;width:12px;height:12px;border-radius:3px;margin-right:6px;vertical-align:middle}
table{width:100%;border-collapse:collapse;font-size:13px}
th{text-align:left;color:var(--muted);font-weight:600;border-bottom:2px solid var(--line);padding:8px 10px}
td{border-bottom:1px solid var(--line);padding:8px 10px}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
td.id{color:var(--muted);font-variant-numeric:tabular-nums;white-space:nowrap}
td.over{color:var(--red);font-weight:600} td.under{color:var(--green);font-weight:600}
table.cmp{font-size:14px} table.cmp td,table.cmp th{padding:10px 12px}
table.cmp td:first-child{font-weight:600}
td.win{background:#dcfce7;color:#166534;font-weight:700}
.sub{font-size:11px;color:var(--muted);font-weight:400;margin-top:2px}
td.win .sub{color:#3f8f5b}
.empty{color:var(--muted);text-align:center;padding:18px}
.scroll{max-height:520px;overflow:auto;border:1px solid var(--line);border-radius:10px}
.scroll table thead th{position:sticky;top:0;background:var(--card)}
footer{color:var(--muted);font-size:12px;text-align:center;margin-top:24px}
.note{background:#fff7ed;border:1px solid #fed7aa;color:#9a3412;border-radius:10px;padding:10px 14px;font-size:13px;margin-bottom:20px}
@media (max-width:780px){.kpis{grid-template-columns:repeat(2,1fr)}.grid2,.split{grid-template-columns:1fr}}
@media print{
  body{background:#fff}.wrap{max-width:none;padding:0}
  header.hero{box-shadow:none}section.card,.kpi{box-shadow:none;border:1px solid var(--line)}
  section.card{break-inside:avoid}.scroll{max-height:none;overflow:visible}
}
'@
}

function Get-DevMetrics {
    param($Name, $WorkItems, $Changesets, $MonthList, $DoneStates)
    $wi = @($WorkItems)
    foreach ($it in $wi) {
        $eff = if ($it.Closed) { $it.Closed } else { $it.Changed }
        $it | Add-Member -NotePropertyName DoneDate -NotePropertyValue $eff -Force
    }
    $done = @($wi | Where-Object { $DoneStates -contains $_.State })
    $open = @($wi | Where-Object { $DoneStates -notcontains $_.State })
    $est  = @($wi | Where-Object { $_.Original -gt 0 })
    $planned = [double](($est | Measure-Object Original -Sum).Sum)
    $actual  = [double](($est | Measure-Object Completed -Sum).Sum)
    $acc = if ($planned -gt 0) { 100 * $actual / $planned } else { 0 }
    $onBudget = @($est | Where-Object { $_.Completed -le $_.Original * 1.10 -and $_.Completed -gt 0 }).Count
    $budgetPct = if ($est.Count -gt 0) { 100 * $onBudget / $est.Count } else { 0 }
    $dev = $est | Where-Object { $_.Completed -gt 0 } |
        Select-Object *, @{n='Diff';e={ $_.Completed - $_.Original }} |
        Sort-Object { [math]::Abs($_.Diff) } -Descending | Select-Object -First 8

    $onTime = 0; $late = 0
    foreach ($it in $done) {
        $ok = $null
        if ($it.Due -and $it.Closed) { $ok = ($it.Closed.Date -le $it.Due.Date) }
        elseif ($it.Original -gt 0 -and $it.Completed -gt 0) { $ok = ($it.Completed -le $it.Original * 1.15) }
        if ($ok -eq $true) { $onTime++ } elseif ($ok -eq $false) { $late++ }
    }
    $ttPct = if (($onTime + $late) -gt 0) { 100 * $onTime / ($onTime + $late) } else { 0 }
    $projCount = @($wi | Where-Object { $_.Project } | Select-Object -ExpandProperty Project -Unique).Count

    $pbm = @(); $abm = @(); $cbm = @(); $csbm = @()
    foreach ($mk in $MonthList.Key) {
        $miDone = $done   | Where-Object { $_.DoneDate -and $_.DoneDate.ToString('yyyy-MM') -eq $mk }
        $miEst  = $miDone | Where-Object { $_.Original -gt 0 }
        $pbm  += [double](($miEst | Measure-Object Original -Sum).Sum)
        $abm  += [double](($miEst | Measure-Object Completed -Sum).Sum)
        $cbm  += [double](@($miDone).Count)
        $csbm += [double](@($Changesets | Where-Object { $_.Date.ToString('yyyy-MM') -eq $mk }).Count)
    }
    $csTotal = @($Changesets).Count
    $filesTotal = [double](($Changesets | Where-Object { $_.Files } | Measure-Object Files -Sum).Sum)
    $withFiles = @($Changesets | Where-Object { $_.Files }).Count
    $avgFiles = if ($withFiles -gt 0) { $filesTotal / $withFiles } else { 0 }
    $activeMonths = @($csbm | Where-Object { $_ -gt 0 }).Count
    $csPerMonth = if ($activeMonths -gt 0) { $csTotal / $activeMonths } else { 0 }

    return [pscustomobject]@{
        Name = $Name; WorkItems = $wi; Changesets = @($Changesets)
        DoneCount = $done.Count; OpenCount = $open.Count
        Planned = $planned; Actual = $actual; Accuracy = $acc; BudgetPct = $budgetPct; EstCount = $est.Count
        OnTime = $onTime; Late = $late; TermintreuePct = $ttPct
        ProjectCount = $projCount
        CsTotal = $csTotal; FilesTotal = $filesTotal; AvgFiles = $avgFiles; CsPerMonth = $csPerMonth
        PlannedByMonth = $pbm; ActualByMonth = $abm; CountByMonth = $cbm; CsByMonth = $csbm
        Deviations = $dev
    }
}

function Build-DevDetail {
    param($m, $MonthList)
    $chartPlanActual = New-GroupedBarChart -Labels $MonthList.Label -A $m.PlannedByMonth -B $m.ActualByMonth -NameA 'Geplant' -NameB 'Tats&#228;chlich'
    $chartDonut = New-Donut -OnTime $m.OnTime -Late $m.Late
    $devRows = ($m.Deviations | ForEach-Object {
        $sign = if ($_.Diff -gt 0) { 'over' } else { 'under' }
        $diffTxt = if ($_.Diff -gt 0) { "+$(fmt $_.Diff 1)" } else { (fmt $_.Diff 1) }
        "<tr><td class='id'>#$($_.Id)</td><td>$(Esc $_.Title)</td><td class='num'>$(fmt $_.Original 1)</td><td class='num'>$(fmt $_.Completed 1)</td><td class='num $sign'>$diffTxt h</td></tr>"
    }) -join "`n"
    if (-not $devRows) { $devRows = "<tr><td colspan='5' class='empty'>Keine gesch&#228;tzten Aufgaben.</td></tr>" }
    $allRows = ($m.WorkItems | Sort-Object Changed -Descending | ForEach-Object {
        $closedTxt = if ($_.Closed) { $_.Closed.ToString('dd.MM.yyyy') } else { '-' }
        "<tr><td class='id'>#$($_.Id)</td><td>$(Esc $_.Project)</td><td>$(Esc $_.Type)</td><td>$(Esc $_.Title)</td><td>$(Esc $_.State)</td><td class='num'>$(fmt $_.Original 1)</td><td class='num'>$(fmt $_.Completed 1)</td><td>$closedTxt</td></tr>"
    }) -join "`n"
    if (-not $allRows) { $allRows = "<tr><td colspan='8' class='empty'>Keine Aufgaben.</td></tr>" }
    $ttTxt = if (($m.OnTime + $m.Late) -gt 0) { "$([math]::Round($m.TermintreuePct)) %" } else { 'n/a' }
    return @"
  <section class="card">
    <h2>Geplant vs. tats&#228;chlich &ndash; $(Esc $m.Name)</h2>
    <p class="desc">Gesch&#228;tzter Aufwand (OriginalEstimate) gegen&#252;ber tats&#228;chlich erfasster Arbeitszeit (CompletedWork), pro Monat.
      Gesamt: <b>$(fmt $m.Planned 1) h</b> geplant, <b>$(fmt $m.Actual 1) h</b> tats&#228;chlich &rarr; Genauigkeit <b>$(fmt $m.Accuracy 0) %</b>.
      <b>$(fmt $m.BudgetPct 0) %</b> der Aufgaben lagen im Rahmen der Sch&#228;tzung (&plusmn;10 %).</p>
    $chartPlanActual
  </section>

  <section class="card">
    <h2>Gr&#246;&#223;te Sch&#228;tzabweichungen &ndash; $(Esc $m.Name)</h2>
    <p class="desc">Aufgaben mit der gr&#246;&#223;ten Differenz zwischen Plan und Ist. Negative Werte = schneller als geplant.</p>
    <table>
      <thead><tr><th>ID</th><th>Aufgabe</th><th class="num">Plan (h)</th><th class="num">Ist (h)</th><th class="num">Diff</th></tr></thead>
      <tbody>$devRows</tbody>
    </table>
  </section>

  <section class="card">
    <h2>Termintreue &ndash; $(Esc $m.Name)</h2>
    <div class="split">
      <div>$chartDonut</div>
      <div>
        <p style="font-size:15px;margin:0 0 10px"><b>$($m.OnTime) von $($m.OnTime + $m.Late)</b> bewertbaren Aufgaben wurden p&#252;nktlich abgeschlossen ($ttTxt).</p>
        <p style="color:var(--muted);font-size:13px;margin:0">Bewertbar sind Aufgaben mit F&#228;lligkeitsdatum oder gepflegter Sch&#228;tzung.</p>
      </div>
    </div>
  </section>

  <section class="card">
    <h2>Alle Aufgaben im Detail &ndash; $(Esc $m.Name)</h2>
    <p class="desc">$($m.WorkItems.Count) Aufgaben im Zeitraum, neueste zuerst.</p>
    <div class="scroll">
      <table>
        <thead><tr><th>ID</th><th>Projekt</th><th>Typ</th><th>Titel</th><th>Status</th><th class="num">Plan (h)</th><th class="num">Ist (h)</th><th>Abgeschlossen</th></tr></thead>
        <tbody>$allRows</tbody>
      </table>
    </div>
  </section>
"@
}

function Build-CompareBody {
    param($a, $b, $MonthList, $FteHours = 40)
    $fA = if ($a.Hours -gt 0) { $FteHours / $a.Hours } else { 1 }
    $fB = if ($b.Hours -gt 0) { $FteHours / $b.Hours } else { 1 }

    # norm=$true -> Output-Kennzahl, auf Vollzeit hochgerechnet (faire Basis)
    $rowsDef = @(
        @{ label = 'Aufgaben erledigt';   a = $a.DoneCount;      b = $b.DoneCount;      t = 'int'; norm = $true;  better = 'high' },
        @{ label = 'Offene Aufgaben';      a = $a.OpenCount;      b = $b.OpenCount;      t = 'int'; norm = $false; better = 'none' },
        @{ label = 'Geplant';              a = $a.Planned;        b = $b.Planned;        t = 'h';   norm = $false; better = 'none' },
        @{ label = 'Tats&#228;chlich';     a = $a.Actual;         b = $b.Actual;         t = 'h';   norm = $false; better = 'none' },
        @{ label = 'Sch&#228;tzgenauigkeit'; a = $a.Accuracy;     b = $b.Accuracy;       t = 'pct'; norm = $false; better = 'acc' },
        @{ label = 'Termintreue';          a = $a.TermintreuePct; b = $b.TermintreuePct; t = 'pct'; norm = $false; better = 'high' },
        @{ label = 'Projekte/Kunden';      a = $a.ProjectCount;   b = $b.ProjectCount;   t = 'int'; norm = $false; better = 'none' },
        @{ label = 'Changesets';           a = $a.CsTotal;        b = $b.CsTotal;        t = 'int'; norm = $true;  better = 'high' },
        @{ label = 'Ge&#228;nderte Dateien'; a = $a.FilesTotal;   b = $b.FilesTotal;     t = 'int'; norm = $true;  better = 'high' }
    )
    $tableRows = ($rowsDef | ForEach-Object {
        $row = $_
        $valA = if ($row.norm) { $row.a * $fA } else { $row.a }
        $valB = if ($row.norm) { $row.b * $fB } else { $row.b }
        $va = Format-Metric $valA $row.t
        $vb = Format-Metric $valB $row.t
        $subA = if ($row.norm) { "<div class='sub'>absolut $([int]$row.a)</div>" } else { '' }
        $subB = if ($row.norm) { "<div class='sub'>absolut $([int]$row.b)</div>" } else { '' }
        $lblExtra = if ($row.norm) { " <span class='sub' style='display:inline'>(je Vollzeit)</span>" } else { '' }
        $ca = ''; $cb = ''
        if ($row.better -eq 'high') {
            if ($valA -gt $valB) { $ca = 'win' } elseif ($valB -gt $valA) { $cb = 'win' }
        } elseif ($row.better -eq 'acc') {
            if ([math]::Abs($valA - 100) -lt [math]::Abs($valB - 100)) { $ca = 'win' }
            elseif ([math]::Abs($valB - 100) -lt [math]::Abs($valA - 100)) { $cb = 'win' }
        }
        "<tr><td>$($row.label)$lblExtra</td><td class='num $ca'>$va$subA</td><td class='num $cb'>$vb$subB</td></tr>"
    }) -join "`n"

    # Volumen-Diagramme auf Vollzeit normiert, Stunden-Diagramm absolut (tatsaechlich geleistet)
    $nTasksA = @($a.CountByMonth | ForEach-Object { $_ * $fA })
    $nTasksB = @($b.CountByMonth | ForEach-Object { $_ * $fB })
    $nCsA    = @($a.CsByMonth    | ForEach-Object { $_ * $fA })
    $nCsB    = @($b.CsByMonth    | ForEach-Object { $_ * $fB })
    $chartTasks = New-GroupedBarChart -Labels $MonthList.Label -A $nTasksA -B $nTasksB -NameA (Esc $a.Name) -NameB (Esc $b.Name) -ColorA '#2563eb' -ColorB '#16a34a'
    $chartCs    = New-GroupedBarChart -Labels $MonthList.Label -A $nCsA    -B $nCsB    -NameA (Esc $a.Name) -NameB (Esc $b.Name) -ColorA '#2563eb' -ColorB '#16a34a'
    $chartHours = New-GroupedBarChart -Labels $MonthList.Label -A $a.ActualByMonth -B $b.ActualByMonth -NameA (Esc $a.Name) -NameB (Esc $b.Name) -ColorA '#2563eb' -ColorB '#16a34a'

    $fteTxt = (fmt $FteHours 0)
    return @"
  <section class="card">
    <h2>Kennzahlen im Vergleich &ndash; fair nach Arbeitszeit</h2>
    <p class="desc">
      <b>$(Esc $a.Name)</b> arbeitet <b>$($a.Hours) h/Woche</b> (Faktor &times;$(fmt $fA 2)),
      <b>$(Esc $b.Name)</b> <b>$($b.Hours) h/Woche</b> (Faktor &times;$(fmt $fB 2)).
      Output-Kennzahlen (Aufgaben, Changesets, Dateien) sind auf <b>$fteTxt-Std-Vollzeit hochgerechnet</b>, damit der Vergleich fair ist &ndash; der tats&#228;chliche Wert steht klein als &bdquo;absolut&ldquo; darunter.
      Quoten (Genauigkeit, Termintreue) und Stundenwerte sind arbeitszeitunabh&#228;ngig und bleiben unver&#228;ndert.
      Gr&#252;n = der jeweils g&#252;nstigere Wert.
    </p>
    <table class="cmp">
      <thead><tr><th>Kennzahl</th><th class="num">$(Esc $a.Name)<div class='sub'>$($a.Hours) h/Woche</div></th><th class="num">$(Esc $b.Name)<div class='sub'>$($b.Hours) h/Woche</div></th></tr></thead>
      <tbody>$tableRows</tbody>
    </table>
  </section>

  <section class="card">
    <h2>Erledigte Aufgaben pro Monat <span style="font-size:13px;color:var(--muted);font-weight:400">(auf $fteTxt-h-Vollzeit hochgerechnet)</span></h2>
    $chartTasks
  </section>

  <section class="card">
    <h2>Changesets pro Monat <span style="font-size:13px;color:var(--muted);font-weight:400">(auf $fteTxt-h-Vollzeit hochgerechnet)</span></h2>
    $chartCs
  </section>

  <section class="card">
    <h2>Erfasste Arbeitszeit (Ist) pro Monat <span style="font-size:13px;color:var(--muted);font-weight:400">(tats&#228;chlich geleistet, nicht hochgerechnet)</span></h2>
    $chartHours
  </section>

  <h2 style="margin:34px 0 10px;font-size:21px;border-bottom:2px solid var(--line);padding-bottom:8px">Detailauswertung &middot; $(Esc $a.Name)</h2>
$(Build-DevDetail $a $MonthList)

  <h2 style="margin:34px 0 10px;font-size:21px;border-bottom:2px solid var(--line);padding-bottom:8px">Detailauswertung &middot; $(Esc $b.Name)</h2>
$(Build-DevDetail $b $MonthList)
"@
}

# ---------------------------------------------------------------------------
# HAUPTPROGRAMM
# ---------------------------------------------------------------------------

if ($SkipCertCheck) {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts {
    public static bool Validate(object s, X509Certificate c, X509Chain ch, System.Net.Security.SslPolicyErrors e) { return true; }
}
"@ -ErrorAction SilentlyContinue
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = [TrustAllCerts]::Validate
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
}

$days = [int]([math]::Round($Months * 30.44))
$periodFrom = (Get-Date).AddMonths(-$Months)
$periodTo = Get-Date

Write-Host ""
Write-Host "TFS Personalauswertung" -ForegroundColor Cyan
Write-Host "======================" -ForegroundColor Cyan

# Geteilte Basis
$monthList  = Get-MonthList -Count $Months
$doneStates = @('Closed','Done','Resolved','Completed','Geschlossen','Erledigt','Behoben','Abgeschlossen','Fertig')
$genDate    = (Get-Date).ToString('dd.MM.yyyy HH:mm', $deDE)
$periodTxt  = "$($periodFrom.ToString('dd.MM.yyyy', $deDE)) &ndash; $($periodTo.ToString('dd.MM.yyyy', $deDE))"

# --- Vergleichsmodus: zwei Entwickler ---
$wantCompare = ($Developers -and $Developers.Count -ge 2) -or ($Demo -and $Compare)
if ($wantCompare) {
    Write-Host "[Vergleichsmodus]" -ForegroundColor Yellow
    $cmp = @()
    if ($Demo) {
        $mA = Get-DevMetrics -Name 'Entwickler A (Teilzeit)' -WorkItems (New-DemoWorkItems -Months $Months -Seed 111) -Changesets (New-DemoChangesets -Months $Months -Seed 222) -MonthList $monthList -DoneStates $doneStates
        $mB = Get-DevMetrics -Name 'Entwickler B (Vollzeit)' -WorkItems (New-DemoWorkItems -Months $Months -Seed 333) -Changesets (New-DemoChangesets -Months $Months -Seed 444) -MonthList $monthList -DoneStates $doneStates
        $mA | Add-Member Hours 25 -Force; $mB | Add-Member Hours 40 -Force
        $cmp += $mA; $cmp += $mB
        $projLabel = 'Demo-Vergleich'
    } else {
        if (-not $CollectionUrl) { throw "Bitte -CollectionUrl angeben (oder -Demo -Compare zum Ausprobieren)." }
        $base = $CollectionUrl.TrimEnd('/')
        $projLabel = if ($Project) { $Project } else { 'Alle Projekte (Collection)' }
        Write-Host "Lade Daten von $base (Vergleich) ..." -ForegroundColor Gray
        foreach ($d in $Developers) {
            $nm = if ($d.Name) { $d.Name } elseif ($d.AssignedTo) { $d.AssignedTo } else { $d.Tfvc }
            $as = if ($d.AssignedTo) { $d.AssignedTo } else { '@Me' }
            $tf = if ($d.Tfvc) { $d.Tfvc } else { $as }
            $hrs = if ($d.Hours) { [double]$d.Hours } else { $FteHours }
            Write-Host "  Entwickler: $nm  (AssignedTo=$as, TFVC=$tf, $hrs h/Woche)" -ForegroundColor DarkGray
            $wi = Get-WorkItemData -Base $base -Proj $Project -Days $days -ApiVer $ApiVersion -AssignedTo $as
            try { $cs = Get-ChangesetData -Base $base -Author $tf -From $periodFrom -To $periodTo -ApiVer $ApiVersion -WithFiles:$IncludeChangesetFiles }
            catch { Write-Warning "Changesets fuer $nm nicht ladbar ($($_.Exception.Message))."; $cs = @() }
            $m = Get-DevMetrics -Name $nm -WorkItems $wi -Changesets $cs -MonthList $monthList -DoneStates $doneStates
            $m | Add-Member Hours $hrs -Force
            $cmp += $m
        }
    }
    $a = $cmp[0]; $b = $cmp[1]
    $css = Get-ReportCss
    $bodyInner = Build-CompareBody $a $b $monthList $FteHours
    $demoNote = if ($Demo) { "<div class='note'><b>Demo-Modus:</b> Beispieldaten zur Veranschaulichung. F&#252;r echte Zahlen ohne -Demo, mit -Developers, ausf&#252;hren.</div>" } else { "" }
    $html = @"
<!DOCTYPE html>
<html lang="de">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Entwicklervergleich $($projLabel)</title>
<style>$css</style></head>
<body>
<div class="wrap">
  <header class="hero">
    <h1>Entwicklervergleich</h1>
    <div class="meta"><b>$(Esc $a.Name)</b> vs. <b>$(Esc $b.Name)</b> &nbsp;|&nbsp; Projekt: <b>$($projLabel)</b> &nbsp;|&nbsp; Zeitraum: <b>$periodTxt</b> ($Months Monate) &nbsp;|&nbsp; erstellt am $genDate</div>
  </header>
  $demoNote
  $bodyInner
  <footer>Erstellt mit TfsPersonalReport.ps1 &middot; $genDate &middot; Tipp: Im Browser mit Strg+P als PDF speichern.</footer>
</div>
</body>
</html>
"@
    if (-not $OutFile) {
        $stamp = (Get-Date).ToString('yyyy-MM-dd')
        $OutFile = Join-Path (Get-Location) "Entwicklervergleich_$stamp.html"
    }
    $html | Out-File -FilePath $OutFile -Encoding utf8
    Write-Host ""
    Write-Host "Fertig! Vergleich gespeichert:" -ForegroundColor Green
    Write-Host "  $OutFile" -ForegroundColor White
    Write-Host ""
    Write-Host "Uebersicht (A vs B):" -ForegroundColor Cyan
    Write-Host ("  Aufgaben erledigt : {0} vs {1}" -f $a.DoneCount, $b.DoneCount)
    Write-Host ("  Genauigkeit       : {0} % vs {1} %" -f (fmt $a.Accuracy 0), (fmt $b.Accuracy 0))
    Write-Host ("  Termintreue       : {0} % vs {1} %" -f (fmt $a.TermintreuePct 0), (fmt $b.TermintreuePct 0))
    Write-Host ("  Changesets        : {0} vs {1}" -f $a.CsTotal, $b.CsTotal)
    if ($Open) { Start-Process $OutFile }
    return
}
# --- Ende Vergleichsmodus ---

if ($Demo) {
    Write-Host "[Demo-Modus] Beispieldaten werden erzeugt..." -ForegroundColor Yellow
    $workItems = New-DemoWorkItems -Months $Months
    $changesets = New-DemoChangesets -Months $Months
    $whoAmI = 'Demo-Benutzer'
    $projLabel = 'Demo-Projekt'
} else {
    if (-not $CollectionUrl) {
        throw "Bitte -CollectionUrl angeben (Projekt optional; ohne Projekt wird die gesamte Collection ausgewertet). Oder -Demo zum Ausprobieren."
    }
    $base = $CollectionUrl.TrimEnd('/')
    if (-not $TfvcAuthor) { $TfvcAuthor = "$env:USERDOMAIN\$env:USERNAME" }
    $whoAmI = $TfvcAuthor
    $projLabel = if ($Project) { $Project } else { 'Alle Projekte (Collection)' }

    Write-Host "Lade Daten von $base ..." -ForegroundColor Gray
    $workItems = Get-WorkItemData -Base $base -Proj $Project -Days $days -ApiVer $ApiVersion
    try {
        $changesets = Get-ChangesetData -Base $base -Author $TfvcAuthor -From $periodFrom -To $periodTo -ApiVer $ApiVersion -WithFiles:$IncludeChangesetFiles
    } catch {
        Write-Warning "Changesets konnten nicht geladen werden ($($_.Exception.Message)). Report wird ohne Code-Aktivitaet erstellt."
        $changesets = @()
    }
}

# ---------------------------------------------------------------------------
# Kennzahlen berechnen
# ---------------------------------------------------------------------------

$doneStates = @('Closed','Done','Resolved','Completed','Geschlossen','Erledigt','Behoben','Abgeschlossen','Fertig')
$doneItems = @($workItems | Where-Object { $doneStates -contains $_.State })
$openItems = @($workItems | Where-Object { $doneStates -notcontains $_.State })

# 1) Geplant vs. tatsaechlich
$estItems = @($workItems | Where-Object { $_.Original -gt 0 })
$totalPlanned = ($estItems | Measure-Object Original -Sum).Sum
$totalActual  = ($estItems | Measure-Object Completed -Sum).Sum
$overallAccuracy = if ($totalPlanned -gt 0) { 100 * $totalActual / $totalPlanned } else { 0 }
$onBudget = @($estItems | Where-Object { $_.Completed -le $_.Original * 1.10 -and $_.Completed -gt 0 }).Count
$budgetPct = if ($estItems.Count -gt 0) { 100 * $onBudget / $estItems.Count } else { 0 }

# groesste Abweichungen
$deviations = $estItems | Where-Object { $_.Completed -gt 0 } |
    Select-Object *, @{n='Diff';e={ $_.Completed - $_.Original }} |
    Sort-Object { [math]::Abs($_.Diff) } -Descending | Select-Object -First 8

# Effektives Abschlussdatum je erledigter Aufgabe (Closed, sonst letzte Aenderung)
foreach ($it in $workItems) {
    $it | Add-Member -NotePropertyName Done -NotePropertyValue ($doneStates -contains $it.State) -Force
    $eff = if ($it.Closed) { $it.Closed } else { $it.Changed }
    $it | Add-Member -NotePropertyName DoneDate -NotePropertyValue $eff -Force
}

# 2) Termintreue
$onTime = 0; $late = 0
foreach ($it in $doneItems) {
    $ok = $null
    if ($it.Due -and $it.Closed) { $ok = ($it.Closed.Date -le $it.Due.Date) }
    elseif ($it.Original -gt 0 -and $it.Completed -gt 0) { $ok = ($it.Completed -le $it.Original * 1.15) }
    if ($ok -eq $true) { $onTime++ } elseif ($ok -eq $false) { $late++ }
}

# 3) Volumen
$projectCount = @($workItems | Where-Object { $_.Project } | Select-Object -ExpandProperty Project -Unique).Count

# Monatsreihen
$monthList = Get-MonthList -Count $Months
$monthKeys = $monthList.Key
$plannedByMonth = @(); $actualByMonth = @(); $countByMonth = @(); $csByMonth = @()
foreach ($mk in $monthKeys) {
    $miDone = $doneItems | Where-Object { $_.DoneDate -and $_.DoneDate.ToString('yyyy-MM') -eq $mk }
    $miEst  = $miDone     | Where-Object { $_.Original -gt 0 }
    $plannedByMonth += [double](($miEst | Measure-Object Original -Sum).Sum)
    $actualByMonth  += [double](($miEst | Measure-Object Completed -Sum).Sum)
    $countByMonth   += [double](@($miDone).Count)
    $csByMonth      += [double](@($changesets | Where-Object { $_.Date.ToString('yyyy-MM') -eq $mk }).Count)
}

# 4) Code-Aktivitaet
$csTotal = @($changesets).Count
$filesTotal = ($changesets | Where-Object { $_.Files } | Measure-Object Files -Sum).Sum
$avgFiles = if (($changesets | Where-Object { $_.Files }).Count -gt 0) { $filesTotal / ($changesets | Where-Object { $_.Files }).Count } else { 0 }
$activeMonths = @($csByMonth | Where-Object { $_ -gt 0 }).Count
$csPerMonth = if ($activeMonths -gt 0) { $csTotal / $activeMonths } else { 0 }

# ---------------------------------------------------------------------------
# HTML zusammenbauen
# ---------------------------------------------------------------------------

$accClass = if ($overallAccuracy -le 105 -and $overallAccuracy -ge 90) { 'good' } elseif ($overallAccuracy -le 120) { 'warn' } else { 'bad' }

# KPI-Karten
$kpis = @(
    @{ label='Aufgaben erledigt'; value=[string]$doneItems.Count; sub="$($openItems.Count) noch offen"; cls='' },
    @{ label='Geplant (gesamt)';  value="$(fmt $totalPlanned 0) h"; sub="$($estItems.Count) gesch&#228;tzte Aufgaben"; cls='' },
    @{ label='Tats&#228;chlich (gesamt)'; value="$(fmt $totalActual 0) h"; sub="erfasste Arbeitszeit"; cls='' },
    @{ label='Sch&#228;tzgenauigkeit'; value="$(fmt $overallAccuracy 0) %"; sub='Ist / Plan (100% = punktgenau)'; cls=$accClass },
    @{ label='Termintreue'; value=$(if(($onTime+$late) -gt 0){"$([math]::Round(100*$onTime/($onTime+$late))) %"}else{'n/a'}); sub="$onTime von $($onTime+$late) p&#252;nktlich"; cls='' },
    @{ label='Projekte'; value=[string]$projectCount; sub='Projekte/Kunden mit Beteiligung'; cls='' },
    @{ label='Changesets'; value=[string]$csTotal; sub="$(fmt $csPerMonth 1) / aktiver Monat"; cls='' },
    @{ label='Ge&#228;nderte Dateien'; value=$(if($filesTotal){[string][int]$filesTotal}else{'n/a'}); sub=$(if($avgFiles){"&#216; $(fmt $avgFiles 1) / Changeset"}else{'-IncludeChangesetFiles f&#252;r Details'}); cls='' }
)
$kpiHtml = ($kpis | ForEach-Object {
    "<div class='kpi $($_.cls)'><div class='kpi-val'>$($_.value)</div><div class='kpi-lbl'>$($_.label)</div><div class='kpi-sub'>$($_.sub)</div></div>"
}) -join "`n"

# Diagramme
$chartPlanActual = New-GroupedBarChart -Labels $monthList.Label -A $plannedByMonth -B $actualByMonth -NameA 'Geplant' -NameB 'Tats&#228;chlich'
$chartVolume     = New-LineChart -Labels $monthList.Label -Values $countByMonth
$chartDonut      = New-Donut -OnTime $onTime -Late $late
$chartCs         = New-BarChart -Labels $monthList.Label -Values $csByMonth -Color '#ea580c'

# Tabelle: groesste Abweichungen
$devRows = ($deviations | ForEach-Object {
    $sign = if ($_.Diff -gt 0) { 'over' } else { 'under' }
    $diffTxt = if ($_.Diff -gt 0) { "+$(fmt $_.Diff 1)" } else { (fmt $_.Diff 1) }
    "<tr><td class='id'>#$($_.Id)</td><td>$(Esc $_.Title)</td><td class='num'>$(fmt $_.Original 1)</td><td class='num'>$(fmt $_.Completed 1)</td><td class='num $sign'>$diffTxt h</td></tr>"
}) -join "`n"
if (-not $devRows) { $devRows = "<tr><td colspan='5' class='empty'>Keine gesch&#228;tzten Aufgaben im Zeitraum.</td></tr>" }

# Tabelle: alle Aufgaben
$allRows = ($workItems | Sort-Object Changed -Descending | ForEach-Object {
    $closedTxt = if ($_.Closed) { $_.Closed.ToString('dd.MM.yyyy') } else { '-' }
    "<tr><td class='id'>#$($_.Id)</td><td>$(Esc $_.Project)</td><td>$(Esc $_.Type)</td><td>$(Esc $_.Title)</td><td>$(Esc $_.State)</td><td class='num'>$(fmt $_.Original 1)</td><td class='num'>$(fmt $_.Completed 1)</td><td>$closedTxt</td></tr>"
}) -join "`n"
if (-not $allRows) { $allRows = "<tr><td colspan='8' class='empty'>Keine Aufgaben gefunden.</td></tr>" }

$genDate = (Get-Date).ToString('dd.MM.yyyy HH:mm', $deDE)
$periodTxt = "$($periodFrom.ToString('dd.MM.yyyy', $deDE)) &ndash; $($periodTo.ToString('dd.MM.yyyy', $deDE))"

$css = Get-ReportCss

$demoNote = if ($Demo) { "<div class='note'><b>Demo-Modus:</b> Dieser Report basiert auf Beispieldaten zur Veranschaulichung. F&#252;r echte Zahlen das Skript mit <code>-CollectionUrl</code> und <code>-Project</code> ausf&#252;hren.</div>" } else { "" }

$html = @"
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Personalauswertung $($projLabel)</title>
<style>$css</style>
</head>
<body>
<div class="wrap">
  <header class="hero">
    <h1>Personalauswertung &middot; Leistungs&#252;berblick</h1>
    <div class="meta"><b>$($whoAmI)</b> &nbsp;|&nbsp; Projekt: <b>$($projLabel)</b> &nbsp;|&nbsp; Zeitraum: <b>$periodTxt</b> ($Months Monate) &nbsp;|&nbsp; erstellt am $genDate</div>
  </header>

  $demoNote

  <div class="kpis">
    $kpiHtml
  </div>

  <section class="card">
    <h2>1 &middot; Geplant vs. tats&#228;chlich</h2>
    <p class="desc">Gesch&#228;tzter Aufwand (OriginalEstimate) gegen&#252;ber tats&#228;chlich erfasster Arbeitszeit (CompletedWork), pro Monat.
       Gesamt: <b>$(fmt $totalPlanned 1) h</b> geplant, <b>$(fmt $totalActual 1) h</b> tats&#228;chlich &rarr; Genauigkeit <b>$(fmt $overallAccuracy 0) %</b>.
       <b>$(fmt $budgetPct 0) %</b> der Aufgaben lagen im Rahmen der Sch&#228;tzung (&plusmn;10 %).</p>
    $chartPlanActual
  </section>

  <section class="card">
    <h2>Gr&#246;&#223;te Sch&#228;tzabweichungen</h2>
    <p class="desc">Aufgaben mit der gr&#246;&#223;ten Differenz zwischen Plan und Ist. Negative Werte = schneller als geplant.</p>
    <table>
      <thead><tr><th>ID</th><th>Aufgabe</th><th class="num">Plan (h)</th><th class="num">Ist (h)</th><th class="num">Diff</th></tr></thead>
      <tbody>$devRows</tbody>
    </table>
  </section>

  <section class="card">
    <h2>2 &middot; Termintreue</h2>
    <p class="desc">Anteil p&#252;nktlich abgeschlossener Aufgaben: Abschluss vor dem F&#228;lligkeitsdatum bzw. &ndash; wenn kein F&#228;lligkeitsdatum gesetzt ist &ndash; innerhalb der Sch&#228;tzung (+15 %).</p>
    <div class="split">
      <div>$chartDonut</div>
      <div>
        <p style="font-size:15px;margin:0 0 10px"><b>$onTime von $($onTime+$late)</b> bewertbaren Aufgaben wurden p&#252;nktlich abgeschlossen.</p>
        <p style="color:var(--muted);font-size:13px;margin:0">
          Bewertbar sind Aufgaben mit F&#228;lligkeitsdatum oder mit gepflegter Sch&#228;tzung.
        </p>
      </div>
    </div>
  </section>

  <section class="card">
    <h2>3 &middot; Volumen</h2>
    <p class="desc">Erledigte Aufgaben pro Monat im Zeitverlauf.</p>
    $chartVolume
  </section>

  <section class="card">
    <h2>4 &middot; Code-Aktivit&#228;t (TFVC)</h2>
    <p class="desc">Check-ins (Changesets) pro Monat. Gesamt <b>$csTotal</b> Changesets$(if($filesTotal){", <b>$([int]$filesTotal)</b> ge&#228;nderte Dateien"}else{''}) im Zeitraum.</p>
    $chartCs
  </section>

  <section class="card">
    <h2>Alle Aufgaben im Detail</h2>
    <p class="desc">$($workItems.Count) Aufgaben im Zeitraum, neueste zuerst.</p>
    <div class="scroll">
      <table>
        <thead><tr><th>ID</th><th>Projekt</th><th>Typ</th><th>Titel</th><th>Status</th><th class="num">Plan (h)</th><th class="num">Ist (h)</th><th>Abgeschlossen</th></tr></thead>
        <tbody>$allRows</tbody>
      </table>
    </div>
  </section>

  <footer>
    Erstellt mit TfsPersonalReport.ps1 &middot; $genDate &middot; Tipp: Im Browser mit Strg+P als PDF speichern.
  </footer>
</div>
</body>
</html>
"@

# ---------------------------------------------------------------------------
# Speichern
# ---------------------------------------------------------------------------

if (-not $OutFile) {
    $stamp = (Get-Date).ToString('yyyy-MM-dd')
    $suffix = if ($Demo) { 'Demo' } elseif ($Project) { ($Project -replace '[^\w\-]', '_') } else { 'AlleProjekte' }
    $OutFile = Join-Path (Get-Location) "Personalauswertung_${suffix}_$stamp.html"
}
$html | Out-File -FilePath $OutFile -Encoding utf8

Write-Host ""
Write-Host "Fertig! Report gespeichert:" -ForegroundColor Green
Write-Host "  $OutFile" -ForegroundColor White
Write-Host ""
Write-Host "Uebersicht:" -ForegroundColor Cyan
Write-Host ("  Aufgaben erledigt : {0}" -f $doneItems.Count)
Write-Host ("  Geplant / Ist     : {0} h / {1} h  (Genauigkeit {2} %)" -f (fmt $totalPlanned 1), (fmt $totalActual 1), (fmt $overallAccuracy 0))
Write-Host ("  Termintreue       : {0} von {1} puenktlich" -f $onTime, ($onTime + $late))
Write-Host ("  Projekte          : {0}" -f $projectCount)
Write-Host ("  Changesets        : {0}" -f $csTotal)

if ($Open) {
    Start-Process $OutFile
}
