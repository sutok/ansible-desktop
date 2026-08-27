<#
.SYNOPSIS
    CSV をもとに、実行中の Windows 端末へ規定要件に沿ったローカルユーザーを一括作成します。

.DESCRIPTION
    本スクリプトは以下の要件を満たすローカルアカウントを作成します。

      ユーザー名        : 英数字のみ（20 文字以内）
      フルネーム        : 「姓, 名」形式のローマ字（例: Sasaki, Ryo）
                          CSV の LastName / FirstName 列から自動で組み立てます
      パスワード        : 16 文字以上の英数字記号。CSV 未記入なら自動生成
      所属グループ      : Users (S-1-5-32-545) と Remote Desktop Users (S-1-5-32-555)
      パスワード無期限  : はい
      パスワード変更可否: ユーザー自身による変更を許可（変更できない = いいえ）
      アカウント無効化  : しない（有効で作成）
      アカウントロック  : 解除された状態を保証する

    ■ ユーザーの削除
      CSV の先頭列 Delete に「True」と記入した行は、作成ではなく **削除** が実行されます。
      列の並び順そのものは見ておらず、ヘッダーの列名だけで判定します。
      削除は取り消せないため、実行前に対象一覧を表示して確認を求めます（-Force で省略可）。
      組み込みアカウント（Administrator / Guest / DefaultAccount / WDAGUtilityAccount）と
      実行中のユーザー自身は、誤操作防止のため削除できません。

    ■ 「次回ログオン時にパスワード変更が必要」について
      Windows の仕様上、「パスワードを無期限にする」と「次回ログオン時にパスワードの
      変更が必要」は同時に設定できません（無期限をオンにすると、変更要求のチェック
      ボックスがグレーアウトします）。
      本スクリプトは要件どおり **無期限を優先** し、次回ログオン時の変更要求は設定
      しません。運用上どうしても初回変更を強制したい場合は -ForceChangeAtLogon を
      指定してください。その場合は無期限設定が自動的に無効になります。

.PARAMETER CsvPath
    入力 CSV のパス。

.PARAMETER Encoding
    CSV の文字コード。Excel 保存の日本語 CSV は Shift_JIS なので Default（既定値）。

.PARAMETER MinPasswordLength
    パスワードの最小文字数。既定 16。自動生成時の長さにもなります。

.PARAMETER ForceChangeAtLogon
    「次回ログオン時にパスワード変更が必要」を設定します。
    指定すると「パスワード無期限」は自動的に無効になります（Windows の仕様上の排他）。

.PARAMETER UpdateExisting
    同名ユーザーが既に存在する場合に、スキップせず要件どおりに更新します。

.PARAMETER RemoveProfile
    ユーザー削除時に、ユーザープロファイル（C:\Users\<名前> 配下）も併せて削除します。
    既定では削除しません（アカウントだけを消し、データは残します）。

.PARAMETER Force
    削除実行前の確認プロンプトを表示せずに続行します。
    タスクスケジューラ等から無人実行する場合に使用してください。

.PARAMETER SkipPasswordOutput
    結果 CSV にパスワードを書き出しません。

.PARAMETER ResultPath
    結果 CSV の出力先。既定はスクリプトと同じ場所。

.PARAMETER LogPath
    実行ログの出力先。既定はスクリプトと同じ場所。

.EXAMPLE
    # まず変更せずに実行内容を確認する
    .\Add-LocalUsersFromCsv.ps1 -CsvPath .\users.csv -WhatIf

.EXAMPLE
    # 実行
    .\Add-LocalUsersFromCsv.ps1 -CsvPath .\users.csv

.EXAMPLE
    # 初回ログオン時のパスワード変更を強制する（無期限設定は無効になります）
    .\Add-LocalUsersFromCsv.ps1 -CsvPath .\users.csv -ForceChangeAtLogon

.EXAMPLE
    # 削除対象（Delete=True）を含む CSV を、確認プロンプトなしで実行する
    .\Add-LocalUsersFromCsv.ps1 -CsvPath .\users.csv -Force

.EXAMPLE
    # 削除時にユーザープロファイル（C:\Users\<名前>）も消す
    .\Add-LocalUsersFromCsv.ps1 -CsvPath .\users.csv -RemoveProfile

.NOTES
    Version   : 2.2
    対象      : Windows 10 / 11 / Windows Server 2016 以降
    必要権限  : ローカル Administrators
    実行方法  : PowerShell を「管理者として実行」で開いてから実行してください。
                実行ポリシーで止まる場合:
                  PowerShell -ExecutionPolicy Bypass -File .\Add-LocalUsersFromCsv.ps1 -CsvPath .\users.csv
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $CsvPath,

    [ValidateSet('Default', 'UTF8', 'Unicode', 'UTF32', 'ASCII', 'BigEndianUnicode', 'OEM')]
    [string] $Encoding = 'Default',

    [ValidateRange(8, 127)]
    [int] $MinPasswordLength = 16,

    [switch] $ForceChangeAtLogon,

    [switch] $UpdateExisting,

    [switch] $RemoveProfile,

    [switch] $Force,

    [switch] $SkipPasswordOutput,

    [string] $ResultPath,

    [string] $LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
#  要件定義（ここを変えれば全ユーザーの既定値が変わります）
# ============================================================================

# 所属させるグループ。well-known SID で指定するため OS の表示言語に依存しない。
$Script:RequiredGroups = @(
    @{ Sid = 'S-1-5-32-545'; Label = 'Users';                Short = 'Users' }
    @{ Sid = 'S-1-5-32-555'; Label = 'Remote Desktop Users'; Short = 'RDP'   }
)

# パスワードを無期限にするか。-ForceChangeAtLogon 指定時は排他のため false に落とす。
$Script:PasswordNeverExpires = -not $ForceChangeAtLogon

# ユーザー名: 英数字のみ・20 文字以内
$Script:UserNamePattern = '^[A-Za-z0-9]{1,20}$'

# 姓 / 名: ローマ字のみ（アポストロフィとハイフンを含む姓に対応: O'Brien, Smith-Jones）
$Script:NamePattern = "^[A-Za-z][A-Za-z'\-]*$"

# パスワードに使用を許可する文字: 英数字 + ASCII 記号（空白は不可）
$Script:PasswordAllowedPattern = '^[A-Za-z0-9!-/:-@\[-`{-~]+$'

$Script:Summary = [ordered]@{
    Total = 0; Created = 0; Updated = 0; Deleted = 0; Skipped = 0; Failed = 0
}

# 削除を禁止する組み込みアカウントの RID（SID の末尾）
#   500 = Administrator / 501 = Guest / 503 = DefaultAccount / 504 = WDAGUtilityAccount
$Script:ProtectedRidPattern = '-(500|501|503|504)$'

# 削除フラグとして True と解釈する値
$Script:TruePattern = '^(?i:true|yes|y|1|はい|削除|○)$'

# CSV の列名。左が正規名（スクリプト内で使う名前）、右が受け付ける実際の列名。
# 列の「並び順」ではなく、この表との一致で列を認識する。
# Delete を先頭列にしても末尾列にしても動作は変わらない。
$Script:ColumnAliases = [ordered]@{
    Delete           = @('Delete', '削除', '削除フラグ')
    UserName         = @('UserName', 'ユーザー名', 'ログオン名')
    LastName         = @('LastName', '姓')
    FirstName        = @('FirstName', '名')
    Password         = @('Password', 'パスワード')
    Description      = @('Description', '説明', '備考')
    AdditionalGroups = @('AdditionalGroups', '追加グループ')
}

# 「正規名 → CSV の実際の列名」の対応表。CSV 読み込み後に組み立てる。
$Script:ColumnLookup = @{}

# 先頭列の列名に混入しうる BOM の「見え方」の一覧。
#   UTF-8 BOM 付きの CSV を ANSI として読むと、BOM のバイト列 EF BB BF が
#   そのコードページの文字として列名の頭に残る。見える文字はコードページ次第
#   （CP1252 なら 3 文字、CP932 なら 2 文字）なので、実行時にデコードして求める。
#   ※ ここで文字リテラルを使わないこと。スクリプトが Shift_JIS に変換されると
#     CP932 に無い文字が '?' に置換され、比較にも正規表現にも使えなくなる。
$Script:BomVariants = @([string][char]0xFEFF)
$bomBytes = [byte[]] @(0xEF, 0xBB, 0xBF)
$codePages = @(
    [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
    932    # 日本語 Windows の ANSI
    1252   # 欧文 Windows の ANSI
)
foreach ($cp in $codePages) {
    try {
        $variant = [System.Text.Encoding]::GetEncoding($cp).GetString($bomBytes)
        if ($variant -and $Script:BomVariants -notcontains $variant) {
            $Script:BomVariants += $variant
        }
    } catch {
        # そのコードページが使えない環境なら無視してよい
    }
}

# ============================================================================
#  ヘルパー関数
# ============================================================================

function Write-Step {
    param([string] $Message, [ValidateSet('Info','Good','Warn','Bad')][string] $Level = 'Info')
    $color = switch ($Level) { 'Good' {'Green'} 'Warn' {'Yellow'} 'Bad' {'Red'} default {'Cyan'} }
    Write-Host $Message -ForegroundColor $color
}

function Test-Administrator {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        if (-not $IsWindows) { return $true }   # 非 Windows（テスト実行）
    }
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-CompliantPassword {
    <#
        要件（英数字記号・指定文字数以上）を満たすランダムパスワードを生成する。
        大文字・小文字・数字・記号から各 1 文字以上を必ず含めたうえでシャッフルするため、
        Windows の「複雑さの要件を満たす」ポリシーが有効でも必ず通る。
        紛らわしい文字（0/O、1/l/I）は視認性のため除外。
    #>
    param([int] $Length = 16)

    $upper  = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower  = 'abcdefghijkmnopqrstuvwxyz'
    $digit  = '23456789'
    # コマンドラインやスクリプトへの貼り付けで事故になりにくい記号に限定
    $symbol = '!#%&*+-=?@_'
    $all    = $upper + $lower + $digit + $symbol

    $bytes = New-Object 'byte[]' 512
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }

    $chars = New-Object System.Collections.Generic.List[char]
    $chars.Add($upper[$bytes[0] % $upper.Length])
    $chars.Add($lower[$bytes[1] % $lower.Length])
    $chars.Add($digit[$bytes[2] % $digit.Length])
    $chars.Add($symbol[$bytes[3] % $symbol.Length])
    for ($n = 4; $n -lt $Length; $n++) { $chars.Add($all[$bytes[$n % $bytes.Length] % $all.Length]) }

    # Fisher-Yates シャッフル
    for ($n = $chars.Count - 1; $n -gt 0; $n--) {
        $j = $bytes[($n + 128) % $bytes.Length] % ($n + 1)
        $tmp = $chars[$n]; $chars[$n] = $chars[$j]; $chars[$j] = $tmp
    }
    return -join $chars
}

function Test-PasswordCompliant {
    <# CSV で指定されたパスワードが要件を満たすか検証する。問題があれば理由を返す #>
    param([string] $Password, [int] $MinLength)

    if ($Password.Length -lt $MinLength) {
        return "パスワードは $MinLength 文字以上である必要があります（現在 $($Password.Length) 文字）。"
    }
    if ($Password -notmatch $Script:PasswordAllowedPattern) {
        return 'パスワードに使用できない文字（空白や全角文字など）が含まれています。半角の英数字と記号のみ使用できます。'
    }
    return $null
}

function Test-UserNameCompliant {
    param([string] $UserName)
    if ([string]::IsNullOrWhiteSpace($UserName)) { return 'UserName が空です。' }
    if ($UserName -notmatch $Script:UserNamePattern) {
        return "UserName は英数字のみ・20 文字以内である必要があります（指定値: '$UserName'）。"
    }
    return $null
}

function Get-FormattedFullName {
    <# 「姓, 名」形式のフルネームを組み立てる。例: Sasaki, Ryo #>
    param([string] $LastName, [string] $FirstName)

    $ln = $LastName.Trim()
    $fn = $FirstName.Trim()

    if (-not $ln) { throw 'LastName（姓）が空です。' }
    if (-not $fn) { throw 'FirstName（名）が空です。' }
    if ($ln -notmatch $Script:NamePattern) { throw "LastName '$ln' はローマ字（半角英字）で入力してください。" }
    if ($fn -notmatch $Script:NamePattern) { throw "FirstName '$fn' はローマ字（半角英字）で入力してください。" }

    # 先頭を大文字、以降を小文字に正規化（SASAKI / sasaki → Sasaki）
    $norm = {
        param([string] $s)
        # ハイフンやアポストロフィで区切られた各パートを個別に整える（O'brien → O'Brien）
        ($s -split "(?<=['\-])") | ForEach-Object {
            if ($_.Length -gt 0) { $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1).ToLowerInvariant() }
        }
    }
    $lnNorm = -join (& $norm $ln)
    $fnNorm = -join (& $norm $fn)

    return "$lnNorm, $fnNorm"
}

function Set-PasswordExpiredFlag {
    <# 「次回ログオン時にパスワードの変更が必要」を設定する（ADSI 経由・OS 言語非依存） #>
    param([string] $UserName)
    $adsi = [ADSI]"WinNT://./$UserName,user"
    $adsi.Put('PasswordExpired', 1)
    $adsi.SetInfo()
}

function Unlock-LocalAccount {
    <#
        アカウントのロックアウトを解除する（要件「アカウントのロックアウト: いいえ」）。
        Get-LocalUser はロック状態を返さないため ADSI (WinNT) を使う。
        既に解除済みの場合は何もしない。
    #>
    param([string] $UserName)

    $adsi = [ADSI]"WinNT://./$UserName,user"
    if ($adsi.IsAccountLocked -eq $true) {
        $adsi.IsAccountLocked = $false
        $adsi.SetInfo()
        return $true    # 解除した
    }
    return $false       # もともとロックされていない
}

function Get-LockoutPolicySummary {
    <#
        端末のアカウントロックアウトのしきい値を取得する。

        `net accounts` の出力は OS の表示言語によってラベルが変わるうえ、
        コンソールのコードページ次第で文字化けするため文字列一致は不安定。
        代わりに secedit でセキュリティポリシーをエクスポートし、
        言語に依存しないキー名 LockoutBadCount を読む。
    #>
    # $env:TEMP は SYSTEM 実行時などに未設定のことがあるため .NET の API を使う
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("secpol-" + [guid]::NewGuid().ToString() + ".inf")
    try {
        $null = & secedit /export /areas SECURITYPOLICY /cfg $tmp /quiet 2>&1
        if (Test-Path -LiteralPath $tmp) {
            # secedit が出力する .inf は UTF-16LE
            $line = Get-Content -LiteralPath $tmp -Encoding Unicode -ErrorAction Stop |
                    Where-Object { $_ -match '^\s*LockoutBadCount\s*=' } |
                    Select-Object -First 1
            if ($line) {
                $value = ($line -split '=', 2)[1].Trim()
                if ($value -eq '0') {
                    return 'しきい値 0（ログオンに失敗してもロックアウトしません）'
                }
                return "しきい値 $value 回（$value 回連続で失敗するとロックされます）"
            }
        }
        return '(取得できませんでした)'
    } catch {
        # 例外メッセージは複数行になることがあるため 1 行目だけを表示に使う
        $firstLine = ($_.Exception.Message -split "`r?`n")[0]
        return "(取得できませんでした: $firstLine)"
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Test-DeleteFlag {
    <# CSV の Delete 列が「削除する」を意味する値かどうかを判定する #>
    param([AllowNull()][AllowEmptyString()][string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value.Trim() -match $Script:TruePattern)
}

function ConvertTo-ColumnKey {
    <#
        列名を比較用に正規化する。
          ・先頭に混入した BOM とその文字化けを除去する
            UTF-8 BOM 付きの CSV を ANSI として読むと、先頭列の列名の頭に
            BOM のバイト列（EF BB BF）が記号として残る。先頭列は Delete なので、
            これを取りこぼすと「削除列が無い」と誤認して削除行を作成行として扱ってしまう。
            見た目の文字はコードページによって変わるため、実行時に組み立てた
            $Script:BomVariants と前方一致で比較して取り除く。
          ・前後の空白と引用符を除去し、小文字化して大文字小文字の揺れを吸収する

        ※ この関数は ASCII 文字だけで書くこと。
           スクリプトが Shift_JIS に変換されると、CP932 に無い文字（Latin-1 の記号など）は
           '?' に置換され、正規表現として不正なパターンになる。
    #>
    param([AllowNull()][AllowEmptyString()][string] $Name)
    if ([string]::IsNullOrEmpty($Name)) { return '' }

    $key = $Name
    foreach ($bom in $Script:BomVariants) {
        while ($bom -and $key.StartsWith($bom, [System.StringComparison]::Ordinal)) {
            $key = $key.Substring($bom.Length)
        }
    }

    $key = $key.Trim().Trim('"').Trim()
    return $key.ToLowerInvariant()
}

function New-ColumnLookup {
    <#
        CSV のヘッダーから「正規名 → 実際の列名」の対応表を作る。
        列の並び順には一切依存しない。
    #>
    param([string[]] $Columns)

    $byKey = @{}
    foreach ($c in $Columns) {
        $key = ConvertTo-ColumnKey $c
        if ($key -and -not $byKey.ContainsKey($key)) { $byKey[$key] = $c }
    }

    $lookup = @{}
    foreach ($name in $Script:ColumnAliases.Keys) {
        foreach ($alias in $Script:ColumnAliases[$name]) {
            $key = ConvertTo-ColumnKey $alias
            if ($byKey.ContainsKey($key)) {
                $lookup[$name] = $byKey[$key]
                break
            }
        }
    }
    return $lookup
}

function Get-RowValue {
    <# 正規名を指定して CSV の値を取り出す。列が無い / 値が空なら '' を返す #>
    param($Row, [string] $Name)
    if (-not $Script:ColumnLookup.ContainsKey($Name)) { return '' }
    $value = $Row.($Script:ColumnLookup[$Name])
    if ($null -eq $value) { return '' }
    return ([string]$value).Trim()
}

function Test-DeleteRow {
    <# その行が削除行かどうかを判定する。Delete 列が無い CSV では常に $false #>
    param($Row)
    return (Test-DeleteFlag -Value (Get-RowValue -Row $Row -Name 'Delete'))
}

function Test-DeletableUser {
    <#
        削除してよいアカウントかを検証する。
        問題があれば理由の文字列を、削除可能なら $null を返す。
    #>
    param([string] $UserName, $UserObject)

    $sid = $UserObject.SID.Value
    if ($sid -match $Script:ProtectedRidPattern) {
        return "組み込みアカウント（SID: $sid）は削除できません。"
    }
    if ($env:USERNAME -and ($UserName -eq $env:USERNAME)) {
        return '実行中のユーザー自身は削除できません。'
    }
    return $null
}

function Remove-UserProfileFolder {
    <#
        ユーザープロファイル（C:\Users\<名前>）を削除する。
        Remove-LocalUser はアカウントを消すだけでプロファイルは残るため、
        -RemoveProfile 指定時に別途この処理を行う。
        ※ ユーザー削除の「前」に呼ぶこと（SID からプロファイルを特定するため）
    #>
    param([string] $Sid)

    $profile = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$Sid'" -ErrorAction SilentlyContinue
    if (-not $profile) { return $null }
    $path = $profile.LocalPath
    Remove-CimInstance -InputObject $profile -ErrorAction Stop
    return $path
}

function Protect-ResultFile {
    param([string] $Path)
    try {
        $acl = Get-Acl -Path $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $account = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $account, 'FullControl', 'Allow')))
        }
        Set-Acl -Path $Path -AclObject $acl
        return $true
    } catch {
        Write-Warning "結果ファイルの ACL 設定に失敗しました: $($_.Exception.Message)"
        return $false
    }
}

function Test-UserCompliance {
    <#
        作成後のアカウントを読み戻し、要件どおりの状態になっているか検証する。
        戻り値は検証結果のオブジェクト。
    #>
    param([string] $UserName, [string] $ExpectedFullName)

    $u = Get-LocalUser -Name $UserName -ErrorAction Stop

    # PasswordExpires が $null = パスワード無期限
    $neverExpires = ($null -eq $u.PasswordExpires)

    $groupOk = $true
    $groupDetail = @()
    foreach ($g in $Script:RequiredGroups) {
        $isMember = $false
        try {
            $members = @(Get-LocalGroupMember -SID $g.Sid -ErrorAction Stop)
            $isMember = @($members | Where-Object { $_.Name -match "[\\/]$([regex]::Escape($UserName))$" -or $_.Name -eq $UserName }).Count -gt 0
        } catch { $isMember = $false }
        if (-not $isMember) { $groupOk = $false }
        $groupDetail += "$($g.Short)=$(if($isMember){'OK'}else{'NG'})"
    }

    return [pscustomobject]@{
        UserName             = $UserName
        FullName             = $u.FullName
        FullNameOk           = ($u.FullName -eq $ExpectedFullName)
        Enabled              = $u.Enabled
        EnabledOk            = ($u.Enabled -eq $true)
        PasswordNeverExpires = $neverExpires
        PasswordExpiryOk     = ($neverExpires -eq $Script:PasswordNeverExpires)
        UserMayChangePassword = $u.UserMayChangePassword
        ChangeAllowedOk      = ($u.UserMayChangePassword -eq $true)
        Groups               = ($groupDetail -join ' ')
        GroupsOk             = $groupOk
    }
}

# ============================================================================
#  事前チェック
# ============================================================================

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $ResultPath) { $ResultPath = Join-Path $scriptDir "result-$stamp.csv" }
if (-not $LogPath)    { $LogPath    = Join-Path $scriptDir "log-$stamp.txt" }

Write-Step "=============================================================="
Write-Step " ローカルユーザー一括作成スクリプト  v2.2"
Write-Step "=============================================================="
Write-Host "  実行日時     : $(Get-Date -Format 'yyyy/MM/dd HH:mm:ss')"
Write-Host "  コンピュータ : $env:COMPUTERNAME"
Write-Host "  実行者       : $env:USERDOMAIN\$env:USERNAME"
Write-Host "  入力CSV      : $CsvPath"
Write-Host "  文字コード   : $Encoding"
Write-Host ""
Write-Host "  【適用される要件】"
Write-Host "    ユーザー名          : 英数字のみ・20文字以内"
Write-Host "    フルネーム          : 「姓, 名」形式のローマ字（LastName / FirstName 列から生成）"
Write-Host "    パスワード          : $MinPasswordLength 文字以上の英数字記号（未記入なら自動生成）"
Write-Host "    所属グループ        : $(($Script:RequiredGroups | ForEach-Object { $_.Label }) -join ' / ')"
Write-Host "    パスワード無期限    : $(if ($Script:PasswordNeverExpires) { 'はい' } else { 'いいえ' })"
Write-Host "    次回ログオン時に変更: $(if ($ForceChangeAtLogon) { 'はい' } else { 'いいえ（無期限と排他のため）' })"
Write-Host "    ユーザーによる変更  : 許可（変更できない = いいえ）"
Write-Host "    アカウント無効化    : しない"
Write-Host "    アカウントロック    : 解除状態を保証"
Write-Host "    削除                : CSV の Delete 列が True の行は作成ではなく削除を実行"
Write-Host ""

if ($ForceChangeAtLogon) {
    Write-Step "  注意: -ForceChangeAtLogon が指定されたため、パスワード無期限は無効になります。" -Level Warn
    Write-Host ""
}
if ($WhatIfPreference) {
    Write-Step "  モード: WhatIf（実際の変更は行いません）" -Level Warn
    Write-Host ""
}

if (-not (Test-Administrator)) {
    Write-Step "エラー: 管理者権限がありません。" -Level Bad
    Write-Host  "  PowerShell を右クリックして「管理者として実行」で開き直してください。"
    exit 1
}
if (-not (Test-Path -LiteralPath $CsvPath)) {
    Write-Step "エラー: CSV が見つかりません: $CsvPath" -Level Bad
    exit 1
}

$transcriptStarted = $false
try {
    Start-Transcript -Path $LogPath -Force -WhatIf:$false | Out-Null
    $transcriptStarted = $true
} catch {
    Write-Warning "トランスクリプトを開始できませんでした: $($_.Exception.Message)"
}

Write-Host "  端末のロックアウトポリシー: $(Get-LockoutPolicySummary)"
Write-Host "  （しきい値が 0 以外の場合、連続してログオンに失敗するとアカウントがロックされます）"
Write-Host ""

# ============================================================================
#  CSV 読み込み
# ============================================================================

# BOM があれば文字コードはそれで確定する。-Encoding を明示指定していない場合に限り、
# 検出結果を優先する（Excel が UTF-8 BOM 付きで保存した CSV を ANSI で読んで
# 先頭列の列名が壊れる、という事故を防ぐため）。
if (-not $PSBoundParameters.ContainsKey('Encoding')) {
    try {
        $head = [byte[]]::new(4)
        $fs   = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $CsvPath).ProviderPath)
        try   { $read = $fs.Read($head, 0, 4) }
        finally { $fs.Dispose() }

        $detected = $null
        if     ($read -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) { $detected = 'UTF8' }
        elseif ($read -ge 4 -and $head[0] -eq 0xFF -and $head[1] -eq 0xFE -and $head[2] -eq 0x00 -and $head[3] -eq 0x00) { $detected = 'UTF32' }
        elseif ($read -ge 2 -and $head[0] -eq 0xFF -and $head[1] -eq 0xFE) { $detected = 'Unicode' }
        elseif ($read -ge 2 -and $head[0] -eq 0xFE -and $head[1] -eq 0xFF) { $detected = 'BigEndianUnicode' }

        if ($detected -and $detected -ne $Encoding) {
            Write-Host "  CSV の BOM から文字コードを $detected と判定しました（-Encoding で明示指定すると優先されます）。"
            $Encoding = $detected
        }
    } catch {
        Write-Warning "CSV の BOM を確認できませんでした: $($_.Exception.Message)"
    }
}

$effectiveEncoding = $Encoding
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $effectiveEncoding = if ($Encoding -eq 'Default') { 'ansi' } else { $Encoding.ToLowerInvariant() }
}

try {
    $rows = @(Import-Csv -LiteralPath $CsvPath -Encoding $effectiveEncoding)
} catch {
    Write-Step "エラー: CSV の読み込みに失敗しました: $($_.Exception.Message)" -Level Bad
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
    exit 1
}

if ($rows.Count -eq 0) {
    Write-Step "CSV にデータ行がありません。" -Level Warn
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
    exit 1
}

# 列は「並び順」ではなく列名で認識する（Delete が先頭でも末尾でも同じ結果になる）
$columns             = $rows[0].PSObject.Properties.Name
$Script:ColumnLookup = New-ColumnLookup -Columns $columns
$deleteCol           = if ($Script:ColumnLookup.ContainsKey('Delete')) { $Script:ColumnLookup['Delete'] } else { $null }

# 削除行（Delete=True）は UserName だけあればよいので、
# 作成対象の行が 1 件でもある場合にのみ LastName / FirstName を必須とする。
$hasCreateRow = $true
if ($deleteCol) {
    $hasCreateRow = @($rows | Where-Object { -not (Test-DeleteRow -Row $_) }).Count -gt 0
}

$required = if ($hasCreateRow) { @('UserName', 'LastName', 'FirstName') } else { @('UserName') }
$missing  = @($required | Where-Object { -not $Script:ColumnLookup.ContainsKey($_) })
if ($missing.Count -gt 0) {
    Write-Step "エラー: CSV に必須列がありません: $($missing -join ', ')" -Level Bad
    Write-Host  "  検出された列: $($columns -join ', ')"
    Write-Host  "  列名が文字化けしている場合は -Encoding の指定を見直してください。"
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
    exit 1
}

# 認識できた列と、無視する列を明示する（列名の綴り違いに気付けるように）
$recognized = @($Script:ColumnAliases.Keys | Where-Object { $Script:ColumnLookup.ContainsKey($_) })
Write-Host "  認識した列: $($recognized -join ', ')"

$knownKeys = @($Script:ColumnLookup.Values | ForEach-Object { ConvertTo-ColumnKey $_ })
$unknown   = @($columns | Where-Object { $knownKeys -notcontains (ConvertTo-ColumnKey $_) })
if ($unknown.Count -gt 0) {
    Write-Step "  未使用の列（無視します）: $($unknown -join ', ')" -Level Warn
}

foreach ($d in ($rows | Group-Object -Property { Get-RowValue -Row $_ -Name 'UserName' } | Where-Object { $_.Count -gt 1 })) {
    Write-Step "警告: CSV 内でユーザー名 '$($d.Name)' が $($d.Count) 回重複しています。" -Level Warn
}

Write-Step "$($rows.Count) 件のユーザー定義を読み込みました。" -Level Good

# ---- 削除対象の事前確認 ---------------------------------------------------
$deleteRows = @()
if ($deleteCol) {
    $deleteRows = @($rows | Where-Object { Test-DeleteRow -Row $_ })
} else {
    Write-Host "  （削除列 'Delete' はありません。全行が作成/更新の対象です）"
}

if ($deleteRows.Count -gt 0) {
    Write-Host ""
    Write-Step "!! 削除対象が $($deleteRows.Count) 件あります !!" -Level Warn
    foreach ($dr in $deleteRows) { Write-Host "     - $(Get-RowValue -Row $dr -Name 'UserName')" }
    Write-Host ""
    Write-Host "  ユーザーアカウントの削除は取り消せません。"
    if ($RemoveProfile) {
        Write-Step "  -RemoveProfile が指定されています。プロファイル（C:\Users\<名前>）配下のデータも削除されます。" -Level Bad
    } else {
        Write-Host "  プロファイル（C:\Users\<名前>）は残ります。併せて削除するには -RemoveProfile を指定してください。"
    }

    if (-not $Force -and -not $WhatIfPreference) {
        Write-Host ""
        $answer = Read-Host "  上記のユーザーを削除します。続行するには 'yes' と入力してください"
        if ($answer -ne 'yes') {
            Write-Step "  中止しました。" -Level Warn
            if ($transcriptStarted) { Stop-Transcript | Out-Null }
            exit 2
        }
    }
}
Write-Host ""

# ============================================================================
#  メイン処理
# ============================================================================

$results     = New-Object System.Collections.Generic.List[object]
$createdUsers = New-Object System.Collections.Generic.List[object]

foreach ($row in $rows) {

    $Script:Summary.Total++
    $userName = Get-RowValue -Row $row -Name 'UserName'

    Write-Host "--------------------------------------------------------------"
    Write-Host "[$($Script:Summary.Total)/$($rows.Count)] $userName"

    $record = [ordered]@{
        UserName = $userName; FullName = ''; Action = ''
        Password = ''; Groups = ''; Result = ''; Message = ''
    }

    try {
        if (-not $userName) { throw 'UserName が空です。' }

        # ====================================================================
        #  削除処理（Delete 列が True の行）
        #    作成時の命名規則チェックは行わない。既存の任意の名前を削除できる。
        # ====================================================================
        if (Test-DeleteRow -Row $row) {

            $record.Action = 'Delete'
            Write-Step "  削除対象として指定されています。" -Level Warn

            $target = Get-LocalUser -Name $userName -ErrorAction SilentlyContinue
            if (-not $target) {
                Write-Host "  存在しないためスキップします。"
                $record.Result = 'Skipped'; $record.Message = '対象ユーザーが存在しません'
                $Script:Summary.Skipped++
                $results.Add([pscustomobject]$record)
                continue
            }

            $guard = Test-DeletableUser -UserName $userName -UserObject $target
            if ($guard) { throw $guard }

            $targetSid = $target.SID.Value
            $record.FullName = $target.FullName

            if ($PSCmdlet.ShouldProcess("$env:COMPUTERNAME\$userName", 'ローカルユーザーを削除')) {

                # プロファイルはユーザー削除の「前」に消す（SID から特定するため）
                if ($RemoveProfile) {
                    try {
                        $removedPath = Remove-UserProfileFolder -Sid $targetSid
                        if ($removedPath) { Write-Host "  プロファイルを削除しました: $removedPath" }
                        else              { Write-Host "  プロファイルは存在しませんでした。" }
                    } catch {
                        Write-Warning "  プロファイルの削除に失敗しました: $($_.Exception.Message)"
                    }
                }

                Remove-LocalUser -Name $userName -ErrorAction Stop
                Write-Step "  ユーザーを削除しました（SID: $targetSid）。" -Level Good
                $Script:Summary.Deleted++

                if (-not $RemoveProfile) {
                    $record.Message = 'プロファイルは残しました'
                }
            }
            else {
                $record.Action = 'WhatIf(Delete)'
            }

            $record.Result   = 'Success'
            $record.Password = '(削除)'
            $record.Groups   = '(削除)'
            $results.Add([pscustomobject]$record)
            continue
        }

        # ---- ユーザー名の検証（作成/更新時のみ） ------------------------------
        $err = Test-UserNameCompliant -UserName $userName
        if ($err) { throw $err }

        # ---- フルネーム「姓, 名」の組み立て ---------------------------------
        $fullName = Get-FormattedFullName -LastName (Get-RowValue -Row $row -Name 'LastName') -FirstName (Get-RowValue -Row $row -Name 'FirstName')
        $record.FullName = $fullName
        Write-Host "  フルネーム: $fullName"

        $description = Get-RowValue -Row $row -Name 'Description'

        # ---- パスワード ------------------------------------------------------
        $rawPassword = Get-RowValue -Row $row -Name 'Password'
        $generated   = $false
        if ($rawPassword) {
            $pwErr = Test-PasswordCompliant -Password $rawPassword -MinLength $MinPasswordLength
            if ($pwErr) { throw $pwErr }
        } else {
            $rawPassword = New-CompliantPassword -Length $MinPasswordLength
            $generated = $true
        }
        $securePassword = ConvertTo-SecureString -String $rawPassword -AsPlainText -Force

        # ---- 追加グループ（任意） -------------------------------------------
        $extraGroups = @()
        $extraRaw = Get-RowValue -Row $row -Name 'AdditionalGroups'
        if ($extraRaw) {
            foreach ($g in ($extraRaw -split '[;、]')) {
                if ($g.Trim()) { $extraGroups += $g.Trim() }
            }
        }

        # ---- 既存確認 ---------------------------------------------------------
        $existing = Get-LocalUser -Name $userName -ErrorAction SilentlyContinue
        if ($existing -and -not $UpdateExisting) {
            Write-Step "  既に存在するためスキップします（更新するには -UpdateExisting）。" -Level Warn
            $record.Action = 'Skip'; $record.Result = 'Skipped'; $record.Message = '既存ユーザー'
            $Script:Summary.Skipped++
            $results.Add([pscustomobject]$record)
            continue
        }

        $actionJp = if ($existing) { '更新' } else { '作成' }
        $record.Action = if ($existing) { 'Update' } else { 'Create' }

        if ($PSCmdlet.ShouldProcess("$env:COMPUTERNAME\$userName", "ローカルユーザーを$actionJp")) {

            # ---- 作成 / 更新 --------------------------------------------------
            if ($existing) {
                $p = @{
                    Name                  = $userName
                    Password              = $securePassword
                    FullName              = $fullName
                    AccountNeverExpires   = $true
                    PasswordNeverExpires  = $Script:PasswordNeverExpires
                    UserMayChangePassword = $true      # 「変更できない = いいえ」
                }
                if ($description) { $p['Description'] = $description }
                Set-LocalUser @p
                Write-Step "  ユーザーを更新しました。" -Level Good
                $Script:Summary.Updated++
            }
            else {
                $p = @{
                    Name                = $userName
                    Password            = $securePassword
                    FullName            = $fullName
                    AccountNeverExpires = $true
                }
                if ($description) { $p['Description'] = $description }
                if ($Script:PasswordNeverExpires) { $p['PasswordNeverExpires'] = $true }
                # -UserMayNotChangePassword は付けない = ユーザーによる変更を許可
                New-LocalUser @p | Out-Null
                Write-Step "  ユーザーを作成しました。" -Level Good
                $Script:Summary.Created++
            }

            # ---- 有効化（アカウントを無効にする = いいえ） ---------------------
            Enable-LocalUser -Name $userName

            # ---- ロックアウト解除（アカウントのロックアウト = いいえ） ---------
            try {
                if (Unlock-LocalAccount -UserName $userName) {
                    Write-Host "  ロックアウトされていたため解除しました。"
                }
            } catch {
                Write-Warning "  ロックアウト状態の確認・解除に失敗しました: $($_.Exception.Message)"
            }

            # ---- 次回ログオン時のパスワード変更（-ForceChangeAtLogon 時のみ） --
            if ($ForceChangeAtLogon) {
                try {
                    Set-PasswordExpiredFlag -UserName $userName
                    Write-Host "  次回ログオン時にパスワード変更を要求する設定にしました。"
                } catch {
                    Write-Warning "  パスワード変更要求の設定に失敗しました: $($_.Exception.Message)"
                }
            }

            # ---- グループへの追加 ----------------------------------------------
            $joined = @()
            foreach ($g in $Script:RequiredGroups) {
                try {
                    Add-LocalGroupMember -SID $g.Sid -Member $userName -ErrorAction Stop
                    Write-Host "  グループ '$($g.Label)' に追加しました。"
                    $joined += $g.Label
                } catch {
                    if ($_.Exception.Message -match 'already a member|既にメンバー') {
                        Write-Host "  グループ '$($g.Label)' には既に所属しています。"
                        $joined += $g.Label
                    } else {
                        Write-Warning "  グループ '$($g.Label)' への追加に失敗: $($_.Exception.Message)"
                    }
                }
            }
            foreach ($gn in $extraGroups) {
                try {
                    Add-LocalGroupMember -Group $gn -Member $userName -ErrorAction Stop
                    Write-Host "  追加グループ '$gn' に追加しました。"
                    $joined += $gn
                } catch {
                    if ($_.Exception.Message -match 'already a member|既にメンバー') {
                        $joined += $gn
                    } else {
                        Write-Warning "  追加グループ '$gn' への追加に失敗: $($_.Exception.Message)"
                    }
                }
            }
            $record.Groups = $joined -join ' / '

            $createdUsers.Add([pscustomobject]@{ UserName = $userName; FullName = $fullName })
        }
        else {
            $record.Action = 'WhatIf'
            $record.Groups = ($Script:RequiredGroups | ForEach-Object { $_.Label }) -join ' / '
        }

        $record.Result   = 'Success'
        $record.Password = if ($SkipPasswordOutput) { '(出力なし)' }
                           elseif ($generated)      { $rawPassword }
                           else                     { '(CSV指定)' }
    }
    catch {
        Write-Step "  失敗: $($_.Exception.Message)" -Level Bad
        $record.Result = 'Failed'; $record.Message = $_.Exception.Message
        $Script:Summary.Failed++
    }

    $results.Add([pscustomobject]$record)
}

# ============================================================================
#  作成後の要件適合チェック
# ============================================================================

if ($createdUsers.Count -gt 0) {
    Write-Host ""
    Write-Step "=============================================================="
    Write-Step " 要件適合チェック（作成結果の読み戻し）"
    Write-Step "=============================================================="

    $compliance = New-Object System.Collections.Generic.List[object]
    foreach ($cu in $createdUsers) {
        try {
            $c = Test-UserCompliance -UserName $cu.UserName -ExpectedFullName $cu.FullName
            $allOk = $c.FullNameOk -and $c.EnabledOk -and $c.PasswordExpiryOk -and $c.ChangeAllowedOk -and $c.GroupsOk
            # 見出しは半角のみ。全角を混ぜると Format-Table の桁がずれるため。
            $compliance.Add([pscustomobject]@{
                UserName     = $c.UserName
                FullName     = $c.FullName
                NameOk       = if ($c.FullNameOk)       { 'OK' } else { 'NG' }
                Enabled      = if ($c.EnabledOk)        { 'OK' } else { 'NG' }
                PwdNoExpire  = if ($c.PasswordExpiryOk) { 'OK' } else { 'NG' }
                CanChangePwd = if ($c.ChangeAllowedOk)  { 'OK' } else { 'NG' }
                Groups       = $c.Groups
                Judge        = if ($allOk) { 'PASS' } else { 'FAIL' }
            })
        } catch {
            Write-Warning "$($cu.UserName) の適合チェックに失敗: $($_.Exception.Message)"
        }
    }
    Write-Host "  凡例: NameOk=フルネーム / Enabled=アカウント有効 / PwdNoExpire=パスワード無期限"
    Write-Host "        CanChangePwd=ユーザーによる変更可 / Groups(RDP=Remote Desktop Users) / Judge=総合判定"
    Write-Host ""
    $compliance | Format-Table -AutoSize | Out-String -Width 250 | Write-Host

    $failed = @($compliance | Where-Object { $_.Judge -eq 'FAIL' })
    if ($failed.Count -gt 0) {
        Write-Step "  !! 要件を満たしていないユーザーが $($failed.Count) 件あります: $(($failed.UserName) -join ', ')" -Level Bad
    } else {
        Write-Step "  すべてのユーザーが要件を満たしています。" -Level Good
    }
}

# ============================================================================
#  結果の出力
# ============================================================================

Write-Host ""
Write-Step "=============================================================="
Write-Step " 実行結果"
Write-Step "=============================================================="
Write-Host "  対象    : $($Script:Summary.Total) 件"
Write-Host "  作成    : $($Script:Summary.Created) 件"
Write-Host "  更新    : $($Script:Summary.Updated) 件"
Write-Step  "  削除    : $($Script:Summary.Deleted) 件" -Level $(if ($Script:Summary.Deleted -gt 0) { 'Warn' } else { 'Info' })
Write-Host "  スキップ: $($Script:Summary.Skipped) 件"
if ($Script:Summary.Failed -gt 0) {
    Write-Step "  失敗    : $($Script:Summary.Failed) 件" -Level Bad
} else {
    Write-Host "  失敗    : 0 件"
}
Write-Host ""

$results | Format-Table UserName, FullName, Action, Result, Groups, Message -AutoSize |
    Out-String -Width 250 | Write-Host

try {
    $results | Export-Csv -LiteralPath $ResultPath -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    Write-Step "結果を出力しました: $ResultPath" -Level Good
    if (-not $SkipPasswordOutput) {
        if (Protect-ResultFile -Path $ResultPath) {
            Write-Host "  （パスワードを含むため、アクセス権を Administrators / SYSTEM のみに制限しました）"
        }
        Write-Step "  ※ パスワード配布後は速やかにこのファイルを削除してください。" -Level Warn
    }
} catch {
    Write-Warning "結果 CSV の出力に失敗しました: $($_.Exception.Message)"
}

Write-Host "ログ: $LogPath"
if ($transcriptStarted) { Stop-Transcript | Out-Null }

if ($Script:Summary.Failed -gt 0) { exit 1 } else { exit 0 }
