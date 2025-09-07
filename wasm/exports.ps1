function Get-Headers {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Owner,   # e.g. "torvalds"
        
        [Parameter(Mandatory=$true)]
        [string]$Repo,    # e.g. "linux"

        [string]$Reference = "HEAD" # can be branch name, tag, or commit SHA
    )

    # GitHub API URL for the repository tree
    $uri = "https://api.github.com/repos/$Owner/$Repo/git/trees/$Reference`?recursive=1"

    # GitHub requires a User-Agent header
    $headers = @{ "User-Agent" = "PowerShell-Script" }

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    } catch {
        Write-Error "Failed to query GitHub API: $_"
        return
    }

    if (-not $response.tree) {
        Write-Error "No tree data found. Check that the repo and ref are correct."
        return
    }

    # Filter for .h files and build raw URLs
    return $response.tree |
        Where-Object { $_.path -like "*.h" } |
        ForEach-Object { "https://raw.githubusercontent.com/$Owner/$Repo/$Reference/$($_.path)" }
}

$t = Get-Headers -Owner "libarchive" -Repo "libarchive" -Ref "v3.7.7"

function Get-ExportLines {
    param(
        #pipeline input
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [string]$Url
    )

    process {
        $content = Invoke-WebRequest -Uri $Url | Select-Object -ExpandProperty Content
        $lines = $content -split "`n"
        return $lines | Where-Object {
            $_ -match "__LA_DECL"
        } | Where-Object {
            -not ($_ -like "#*")
        }
    }
}

$l = $t | Get-ExportLines

function Get-Exports {
    param(
        #pipeline input
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [string]$Line
    )

    process {
        if ($Line -match '([\w_]+)\([^(]*$') {
            $matches[1]
        } elseif($Line -match '([\w_]+);?$') {
            $matches[1]
        } else {
            Write-Warning "No match for line: $Line"
        }
    }
}

$e = $l | Get-Exports

$gitroot = git rev-parse --show-toplevel

(&{
    # Always include malloc and free
    "_free"
    "_malloc"
    $e | ForEach-Object { "_$_" }
}) | Where-Object {
    # Filter out unusable exports
    $bad_hits = (& {
        $export = $_
        @(
            "_archive_entry_copy_bhfi" # Windows-specific
            "_archive_read_support_filter_lrzip" # Hard requires lrzip program
            "_archive_write_add_filter_lrzip"
            "_archive_read_support_filter_grzip" # Hard requires grzip program
            "_archive_write_add_filter_grzip"
            "_archive_write_add_filter_program"
            "_archive_write_set_compression_program"
        ) | Where-Object { $export -eq $_ }
        @(
            "_archive_entry_acl_text*" # Deprecated ACL functions
            "_archive_read_support_compression_program*" # Deprecated compression functions
            "_archive_read_support_filter_program*" # Shells out to an external program, which doesn't work in WASM
            "*_w" # Exclude wide-char functions (these are designed for Windows)
        ) | Where-Object { $export -like "$_" }
    })

    $bad_hits.Count -eq 0
} | Out-File "$gitroot/wasm/lib.exports"