#requires -Version 5.1
<#
NoSpamProxy 16.1 Message Tracking Viewer v22
- WPF GUI
- Basic authentication via Connect-Nsp
- Server-side MessageTrack filtering
- Lazy detail loading for selected messages

Tested against the object/cmdlet shapes supplied from NoSpamProxy 16.1.0.4765.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ------------------------- NoSpamProxy login before GUI -------------------------
# Authentication deliberately happens in the console, exactly like the verified test.
try {
    Write-Host "NoSpamProxy-Anmeldung" -ForegroundColor Cyan
    $cred = Get-Credential -Message "NoSpamProxy-Anmeldedaten eingeben"

    if ($null -eq $cred) {
        Write-Host "Anmeldung abgebrochen." -ForegroundColor Yellow
        return
    }

    Write-Host "Verbindung zu NoSpamProxy wird hergestellt ..." -ForegroundColor Gray
    Connect-Nsp `
        -Credential $cred.GetNetworkCredential() `
        -IgnoreServerCertificateErrors

    Write-Host "Anmeldung erfolgreich. GUI wird gestartet." -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "NoSpamProxy-Anmeldung fehlgeschlagen:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    return
}


# ------------------------- Helpers -------------------------

function Show-Error {
    param([string]$Message, [string]$Title = 'Fehler')
    [System.Windows.MessageBox]::Show(
        $Message, $Title,
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
}

function Show-Info {
    param([string]$Message, [string]$Title = 'Information')
    [System.Windows.MessageBox]::Show(
        $Message, $Title,
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    ) | Out-Null
}

function Get-PropValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Format-Nullable {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return '\u2014' }
    if ($Value -is [bool]) {
        if ($Value) { return 'Ja' } else { return 'Nein' }
    }
    return [string]$Value
}

function Format-Bytes {
    param($Bytes)
    if ($null -eq $Bytes -or "$Bytes" -eq '') { return '\u2014' }
    [double]$n = $Bytes
    if ($n -ge 1GB) { return ('{0:N2} GB' -f ($n / 1GB)) }
    if ($n -ge 1MB) { return ('{0:N2} MB' -f ($n / 1MB)) }
    if ($n -ge 1KB) { return ('{0:N1} KB' -f ($n / 1KB)) }
    return ('{0:N0} Bytes' -f $n)
}

function Format-Duration {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return '\u2014' }
    try {
        $ts = [timespan]$Value
        if ($ts.TotalSeconds -lt 1) { return ('{0:N0} ms' -f $ts.TotalMilliseconds) }
        return ('{0:N2} s' -f $ts.TotalSeconds)
    } catch { return [string]$Value }
}

function Get-AddressValue {
    param($Track, [string]$Type)
    $addresses = @(Get-PropValue $Track 'Addresses')
    $matches = foreach ($a in $addresses) {
        if ($null -eq $a) { continue }
        $typeValue = Get-PropValue $a 'Type'
        if ($null -eq $typeValue) { $typeValue = Get-PropValue $a 'AddressType' }

        # Some NSP objects stringify as "Recipient: address@example.org".
        if ($null -eq $typeValue) {
            $s = [string]$a
            if ($s -match ('^\s*' + [regex]::Escape($Type) + '\s*:\s*(.+)$')) {
                $Matches[1].Trim()
                continue
            }
        }

        if ([string]$typeValue -eq $Type) {
            $v = Get-PropValue $a 'Address'
            if ($null -eq $v) { $v = Get-PropValue $a 'Value' }
            if ($null -eq $v) { $v = Get-PropValue $a 'EmailAddress' }
            if ($null -ne $v) { [string]$v }
            else {
                $s = [string]$a
                if ($s -match ':\s*(.+)$') { $Matches[1].Trim() }
            }
        }
    }
    return (@($matches) -join '; ')
}


function Get-ContentFilterSetName {
    param($Reference)
    if ($null -eq $Reference) { return $null }

    foreach ($name in @('Name','ContentFilterSetName')) {
        $v = Get-PropValue $Reference $name
        if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
    }

    $text = [string]$Reference
    if ($text -match '^Content filter set\s+(.+)$') { return $Matches[1].Trim() }
    if ($text -match '^Use parent settings$') { return $null }
    if ($text -match '^Allow any$') { return $null }
    if (-not [string]::IsNullOrWhiteSpace($text)) { return $text.Trim() }
    return $null
}

function Test-UseParentContentFilterSet {
    param($Reference)
    if ($null -eq $Reference) { return $true }
    $text = [string]$Reference
    return ([string]::IsNullOrWhiteSpace($text) -or $text -eq 'Use parent settings')
}

function Get-EffectiveInboundContentFilterSet {
    param([string]$SenderAddress)

    $result = [ordered]@{
        SetName          = $null
        Source           = $null
        Sender           = $SenderAddress
        Domain           = $null
        AddressSetting   = $null
        DomainSetting    = $null
        DefaultSetting   = $null
    }

    if ([string]::IsNullOrWhiteSpace($SenderAddress) -or $SenderAddress -notmatch '@') {
        return [pscustomobject]$result
    }

    $domain = ($SenderAddress -split '@',2)[1]
    $result.Domain = $domain

    # Priority 1: exact partner-address override.
    try {
        $address = Get-NspPartnerAddress -Domain $domain |
            Where-Object { [string]$_.MailAddress -ieq $SenderAddress } |
            Select-Object -First 1

        if ($null -ne $address) {
            $ref = Get-PropValue $address 'InboundContentFilterSet'
            $result.AddressSetting = Format-Nullable $ref
            if (-not (Test-UseParentContentFilterSet $ref)) {
                $result.SetName = Get-ContentFilterSetName $ref
                $result.Source = 'Partner-Adresse'
                return [pscustomobject]$result
            }
        }
        else { $result.AddressSetting = 'Kein Eintrag' }
    }
    catch { $result.AddressSetting = 'Nicht ermittelbar: ' + $_.Exception.Message }

    # Priority 2: partner/domain override.
    try {
        $partner = Get-NspPartner -DomainFilter $domain |
            Where-Object { [string]$_.Domain -ieq $domain } |
            Select-Object -First 1

        if ($null -ne $partner) {
            $ref = Get-PropValue $partner 'InboundContentFilterSet'
            $result.DomainSetting = Format-Nullable $ref
            if (-not (Test-UseParentContentFilterSet $ref)) {
                $result.SetName = Get-ContentFilterSetName $ref
                $result.Source = 'Partner-Domain'
                return [pscustomobject]$result
            }
        }
        else { $result.DomainSetting = 'Kein Partner-Eintrag' }
    }
    catch { $result.DomainSetting = 'Nicht ermittelbar: ' + $_.Exception.Message }

    # Priority 3: global/default partner settings.
    try {
        $defaults = Get-NspDefaultPartnerSettings | Select-Object -First 1
        if ($null -ne $defaults) {
            $ref = Get-PropValue $defaults 'InboundContentFilterSet'
            $result.DefaultSetting = Format-Nullable $ref
            $result.SetName = Get-ContentFilterSetName $ref
            if (-not [string]::IsNullOrWhiteSpace($result.SetName)) {
                $result.Source = 'Standard-Partnereinstellungen'
            }
        }
    }
    catch { $result.DefaultSetting = 'Nicht ermittelbar: ' + $_.Exception.Message }

    return [pscustomobject]$result
}

function Get-QueryItems {
    param($Query)
    if ($null -eq $Query) { return @() }

    $items = New-Object System.Collections.ArrayList
    try {
        $enumerator = $Query.GetEnumerator()
        while ($enumerator.MoveNext()) { [void]$items.Add($enumerator.Current) }
    }
    catch {
        foreach ($x in @($Query)) { [void]$items.Add($x) }
    }
    return @($items)
}

function Test-ContentFilterCondition {
    param($Condition, [string]$FileName, [string]$MimeType)

    $filePattern = [string](Get-PropValue $Condition 'FileName')
    if (-not [string]::IsNullOrWhiteSpace($filePattern)) {
        $matchedName = $false
        foreach ($pattern in ($filePattern -split ';')) {
            $pattern = $pattern.Trim()
            if (-not [string]::IsNullOrWhiteSpace($pattern) -and $FileName -like $pattern) {
                $matchedName = $true; break
            }
        }
        if (-not $matchedName) { return $false }
    }

    $mimeObjects = @(Get-PropValue $Condition 'MimeTypes')
    $mimeValues = @(
        foreach ($m in $mimeObjects) {
            $v = Get-PropValue $m 'MimeType'
            if ($null -eq $v) { $v = [string]$m }
            if (-not [string]::IsNullOrWhiteSpace([string]$v)) { [string]$v }
        }
    )
    if ($mimeValues.Count -gt 0) {
        if ([string]::IsNullOrWhiteSpace($MimeType) -or $MimeType -eq '\u2014') { return $false }
        if (-not ($mimeValues | Where-Object { $_ -ieq $MimeType })) { return $false }
    }

    $min = Get-PropValue $Condition 'MinSize'
    $max = Get-PropValue $Condition 'MaxSize'
    # Size-based conditions cannot be proven when the historical attachment object is absent.
    if ($null -ne $min -or $null -ne $max) { return $false }

    return $true
}

function Resolve-ContentFilterEntry {
    param([string]$SetName, [string]$FileName, [string]$MimeType)
    if ([string]::IsNullOrWhiteSpace($SetName) -or [string]::IsNullOrWhiteSpace($FileName)) { return $null }

    try {
        $set = Get-NspContentFilterSet -Name $SetName | Select-Object -First 1
        if ($null -eq $set) { return $null }

        $query = Get-NspContentFilterSetEntry -ContentFilterSet $set
        $entries = @(Get-QueryItems $query | Sort-Object {[int](Get-PropValue $_ 'Index')})

        foreach ($entry in $entries) {
            $entryName = [string](Get-PropValue $entry 'Name')
            if ([string]::IsNullOrWhiteSpace($entryName)) { continue }

            $conditions = @(Get-NspContentFilterSetEntryCondition `
                -ContentFilterSetName $SetName `
                -ContentFilterSetEntryName $entryName)

            foreach ($condition in $conditions) {
                if (Test-ContentFilterCondition $condition $FileName $MimeType) {
                    return [pscustomobject]@{
                        EntryName = $entryName
                        EntryIndex = Get-PropValue $entry 'Index'
                        Condition = $condition
                        ActionForUntrusted = Get-PropValue $entry 'ActionForUntrustedAndOutboundEMails'
                        ActionForTrusted = Get-PropValue $entry 'ActionForTrustedEmails'
                    }
                }
            }
        }
    }
    catch { return $null }
    return $null
}

function Convert-Status {
    param($Status)
    switch ([string]$Status) {
        'Success'              { 'Erfolgreich' }
        'DeliveryPending'      { 'Zustellung ausstehend' }
        'DispatcherError'      { 'Zustellfehler' }
        'PermanentlyBlocked'   { 'Permanent abgewiesen' }
        'TemporarilyBlocked'   { 'Temporär abgewiesen' }
        'Suppressed'           { 'Angenommen aber nicht zugestellt' }
        'PartialSuccess'       { 'Mehrere Zustellzustände' }
        'DuplicateDrop'        { 'Doppelt' }
        'PutOnHold'            { 'Angehalten' }
        default                { if ("$Status") { [string]$Status } else { '\u2014' } }
    }
}

function Convert-Direction {
    param($Direction)
    switch ([string]$Direction) {
        'FromExternal' { 'Eingehend' }
        'FromLocal'    { 'Ausgehend' }
        'FromInternal' { 'Ausgehend' }
        'Inbound'      { 'Eingehend' }
        'Outbound'     { 'Ausgehend' }
        default        { if ("$Direction") { [string]$Direction } else { '\u2014' } }
    }
}

function Convert-ToRawText {
    param($Object)
    if ($null -eq $Object) { return '\u2014' }
    return (($Object | Format-List * | Out-String -Width 220).TrimEnd())
}

function New-PropertyRows {
    param([hashtable]$Properties)
    $list = New-Object System.Collections.ArrayList
    foreach ($k in $Properties.Keys) {
        [void]$list.Add([pscustomobject]@{
            Eigenschaft = $k
            Wert = Format-Nullable $Properties[$k]
        })
    }
    return $list
}

function Get-SelectedStatuses {
    $result = @()
    foreach ($item in $StatusList.Children) {
        if ($item.IsChecked -eq $true) { $result += [string]$item.Tag }
    }
    return $result
}

function New-StatusItem {
    param([string]$Text, [string]$Value)
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $Text
    $cb.Tag = $Value
    $cb.IsChecked = $true
    $cb.Margin = '2,1,10,1'
    return $cb
}

# ------------------------- XAML -------------------------

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NoSpamProxy Message Tracking Viewer"
        Width="1500" Height="930" MinWidth="1150" MinHeight="700"
        WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style TargetType="TextBox">
      <Setter Property="Margin" Value="3"/>
      <Setter Property="Padding" Value="5,3"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Margin" Value="3"/>
      <Setter Property="Padding" Value="4,2"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Margin" Value="3"/>
      <Setter Property="Padding" Value="12,5"/>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="SelectionMode" Value="Single"/>
      <Setter Property="SelectionUnit" Value="FullRow"/>
      <Setter Property="ClipboardCopyMode" Value="ExcludeHeader"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
    </Style>
  </Window.Resources>

  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="2*"/>
      <RowDefinition Height="3*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Search -->
    <Border Grid.Row="0" BorderBrush="#BBBBBB" BorderThickness="1" CornerRadius="4" Padding="8" Margin="0,0,0,8">
      <Grid x:Name="SearchPanel">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="190"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="190"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="230"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="160"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <TextBlock Grid.Row="0" Grid.Column="0" Text="Von:" VerticalAlignment="Center" Margin="3"/>
        <StackPanel Grid.Row="0" Grid.Column="1" Orientation="Horizontal" Margin="3">
          <DatePicker x:Name="FromDate" Width="125"/>
          <TextBox x:Name="FromTime" Width="55" Margin="5,0,0,0" VerticalContentAlignment="Center" ToolTip="Uhrzeit im Format HH:mm"/>
        </StackPanel>
        <TextBlock Grid.Row="0" Grid.Column="2" Text="Bis:" VerticalAlignment="Center" Margin="10,3,3,3"/>
        <StackPanel Grid.Row="0" Grid.Column="3" Orientation="Horizontal" Margin="3">
          <DatePicker x:Name="ToDate" Width="125"/>
          <TextBox x:Name="ToTime" Width="55" Margin="5,0,0,0" VerticalContentAlignment="Center" ToolTip="Uhrzeit im Format HH:mm"/>
        </StackPanel>
        <TextBlock Grid.Row="0" Grid.Column="4" Text="Richtung:" VerticalAlignment="Center" Margin="10,3,3,3"/>
        <ComboBox x:Name="DirectionBox" Grid.Row="0" Grid.Column="5" Height="28" VerticalContentAlignment="Center">
          <ComboBoxItem Content="Alle" Tag=""/>
          <ComboBoxItem Content="Eingehend" Tag="FromExternal"/>
          <ComboBoxItem Content="Ausgehend" Tag="FromLocal"/>
        </ComboBox>
        <TextBlock Grid.Row="0" Grid.Column="6" Text="Max. Treffer:" VerticalAlignment="Center" Margin="10,3,3,3"/>
        <ComboBox x:Name="MaxResultsBox" Grid.Row="0" Grid.Column="7" Height="28" VerticalContentAlignment="Center">
          <ComboBoxItem Content="100" Tag="100"/>
          <ComboBoxItem Content="250" Tag="250"/>
          <ComboBoxItem Content="500" Tag="500"/>
          <ComboBoxItem Content="1000" Tag="1000"/>
        </ComboBox>
        <ComboBox x:Name="TimePresetBox" Grid.Row="0" Grid.Column="8" Margin="10,3,3,3" MinWidth="145" Height="28" VerticalContentAlignment="Center" ToolTip="NSP-Zeitraumvorgabe">
          <ComboBoxItem Content="Angepasst" Tag="Custom"/>
          <ComboBoxItem Content="seit 30 Minuten" Tag="30m"/>
          <ComboBoxItem Content="seit einer Stunde" Tag="1h"/>
          <ComboBoxItem Content="seit 2 Stunden" Tag="2h"/>
          <ComboBoxItem Content="seit 6 Stunden" Tag="6h"/>
          <ComboBoxItem Content="seit 12 Stunden" Tag="12h"/>
          <ComboBoxItem Content="seit 24 Stunden" Tag="24h"/>
          <ComboBoxItem Content="seit 2 Tagen" Tag="2d"/>
          <ComboBoxItem Content="seit 7 Tagen" Tag="7d"/>
          <ComboBoxItem Content="seit 14 Tagen" Tag="14d"/>
          <ComboBoxItem Content="seit 30 Tagen" Tag="30d"/>
          <ComboBoxItem Content="seit 60 Tagen" Tag="60d"/>
          <ComboBoxItem Content="seit 90 Tagen" Tag="90d"/>
        </ComboBox>

        <TextBlock Grid.Row="1" Grid.Column="0" Text="Absender:" VerticalAlignment="Center" Margin="3"/>
        <TextBox x:Name="SenderBox" Grid.Row="1" Grid.Column="1"/>
        <TextBlock Grid.Row="1" Grid.Column="2" Text="Empfänger:" VerticalAlignment="Center" Margin="10,3,3,3"/>
        <TextBox x:Name="RecipientBox" Grid.Row="1" Grid.Column="3"/>
        <StackPanel Grid.Row="1" Grid.Column="4" Grid.ColumnSpan="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="10,3,3,3">
          <RadioButton x:Name="AddressExactBox" Content="Exakt" IsChecked="True" Margin="0,0,10,0"
                       ToolTip="Exakter Treffer (schneller)"/>
          <RadioButton x:Name="AddressContainsBox" Content="Enthält"
                       ToolTip="Teiltreffer; verwendet *Suchtext*"/>
        </StackPanel>
        <TextBlock Grid.Row="1" Grid.Column="6" Text="Betreff:" VerticalAlignment="Center" Margin="10,3,3,3"/>
        <TextBox x:Name="SubjectBox" Grid.Row="1" Grid.Column="7"/>
        <StackPanel Grid.Row="1" Grid.Column="8" Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="ResetButton" Content="Reset" MinWidth="75" Margin="3"/>
          <Button x:Name="SearchButton" Content="Suchen" MinWidth="110" Margin="3"/>
        </StackPanel>

        <TextBlock Grid.Row="2" Grid.Column="0" Text="Zustellergebnis:" VerticalAlignment="Top" Margin="3,6,8,3"/>
        <StackPanel Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="8" Orientation="Horizontal" Margin="3,5,3,0">
          <WrapPanel x:Name="StatusList" VerticalAlignment="Center"/>
          <Button x:Name="SelectAllStatusButton" Content="Alle" Padding="8,2" Margin="10,0,2,0" MinWidth="50"/>
          <Button x:Name="SelectNoStatusButton" Content="Keine" Padding="8,2" Margin="2,0,0,0" MinWidth="55"/>
        </StackPanel>

        <CheckBox x:Name="AttachmentRejectOnlyBox"
                  Grid.Row="3" Grid.Column="1" Grid.ColumnSpan="8"
                  Content="Nur wegen Anhängen abgelehnte Nachrichten"
                  Margin="3,5,3,1"
                  ToolTip="Zeigt nur permanent abgewiesene Nachrichten, bei denen ContentFiltering eine Ablehnung mit Anhang-/Attachment-Bezug meldet."/>
      </Grid>
    </Border>

    <!-- Results -->
    <DataGrid x:Name="ResultGrid" Grid.Row="1" Margin="0,0,0,8">
      <DataGrid.Columns>
        <DataGridTextColumn Header="Empfangszeit" Binding="{Binding SentText}" Width="145"/>
        <DataGridTextColumn Header="Zustellergebnis" Binding="{Binding StatusText}" Width="175"/>
        <DataGridTextColumn Header="Richtung" Binding="{Binding DirectionText}" Width="95"/>
        <DataGridTextColumn Header="SMTP-Absender" Binding="{Binding Sender}" Width="220"/>
        <DataGridTextColumn Header="Header-Absender" Binding="{Binding HeaderFrom}" Width="220"/>
        <DataGridTextColumn Header="Empfänger" Binding="{Binding Recipient}" Width="240"/>
        <DataGridTextColumn Header="Betreff" Binding="{Binding Subject}" Width="*"/>
        <DataGridTextColumn Header="Anh." Binding="{Binding AttachmentCount}" Width="55"/>
      </DataGrid.Columns>
    </DataGrid>

    <!-- Details -->
    <TabControl x:Name="DetailTabs" Grid.Row="2">
      <TabItem Header="Übersicht">
        <DataGrid x:Name="OverviewGrid">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Eigenschaft" Binding="{Binding Eigenschaft}" Width="230"/>
            <DataGridTextColumn Header="Wert" Binding="{Binding Wert}" Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
      </TabItem>

      <TabItem Header="Adressen">
        <DataGrid x:Name="AddressGrid" AutoGenerateColumns="True"/>
      </TabItem>

      <TabItem Header="Anhänge">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="2*"/>
          </Grid.RowDefinitions>
          <Border x:Name="AttachmentWarningBorder" Grid.Row="0" Background="#FFF4CE" BorderBrush="#D6B656" BorderThickness="1" Padding="7" Margin="4" Visibility="Collapsed">
            <TextBlock x:Name="AttachmentWarning" TextWrapping="Wrap" FontWeight="SemiBold"/>
          </Border>
          <DataGrid x:Name="AttachmentGrid" Grid.Row="1">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Dateiname" Binding="{Binding Name}" Width="*"/>
              <DataGridTextColumn Header="MIME-Type" Binding="{Binding MimeType}" Width="230"/>
              <DataGridTextColumn Header="Größe" Binding="{Binding SizeText}" Width="110"/>
              <DataGridTextColumn Header="Quarantäne" Binding="{Binding QuarantineText}" Width="100"/>
              <DataGridTextColumn Header="Malware-Scan" Binding="{Binding MalwareText}" Width="130"/>
              <DataGridTextColumn Header="Inhaltsfilter" Binding="{Binding FilterSet}" Width="250"/>
              <DataGridTextColumn Header="Filtereintrag" Binding="{Binding FilterEntry}" Width="150"/>
              <DataGridTextColumn Header="Herkunft" Binding="{Binding FilterSource}" Width="180"/>
              <DataGridTextColumn Header="Content-Filteraktion" Binding="{Binding FilterAction}" Width="180"/>
              <DataGridTextColumn Header="Aktionstyp" Binding="{Binding FilterActionType}" Width="110"/>
            </DataGrid.Columns>
          </DataGrid>
          <DataGrid x:Name="AttachmentDetailGrid" Grid.Row="2" Margin="0,5,0,0">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Eigenschaft" Binding="{Binding Eigenschaft}" Width="230"/>
              <DataGridTextColumn Header="Wert" Binding="{Binding Wert}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>

      <TabItem Header="Aktionen">
        <DataGrid x:Name="ActionGrid">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Aktion" Binding="{Binding Name}" Width="230"/>
            <DataGridTextColumn Header="Entscheidung" Binding="{Binding Decision}" Width="150"/>
            <DataGridTextColumn Header="Dauer" Binding="{Binding TimeText}" Width="100"/>
            <DataGridTextColumn Header="Meldung" Binding="{Binding Message}" Width="*"/>
            <DataGridTextColumn Header="Fehler" Binding="{Binding ErrorMessage}" Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
      </TabItem>

      <TabItem Header="Filter">
        <DataGrid x:Name="FilterGrid">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Filter" Binding="{Binding Name}" Width="230"/>
            <DataGridTextColumn Header="SCL" Binding="{Binding Scl}" Width="70"/>
            <DataGridTextColumn Header="Dauer" Binding="{Binding TimeText}" Width="100"/>
            <DataGridTextColumn Header="Meldung" Binding="{Binding Message}" Width="*"/>
            <DataGridTextColumn Header="Fehler" Binding="{Binding ErrorMessage}" Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
      </TabItem>

      <TabItem Header="Verarbeitung">
        <DataGrid x:Name="ActivityGrid" AutoGenerateColumns="True"/>
      </TabItem>

      <TabItem Header="Zustellung">
        <DataGrid x:Name="DeliveryGrid" AutoGenerateColumns="True"/>
      </TabItem>

      <TabItem Header="Rohdaten">
        <TextBox x:Name="RawText" FontFamily="Consolas" FontSize="12"
                 IsReadOnly="True" AcceptsReturn="True" AcceptsTab="True"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                 TextWrapping="NoWrap"/>
      </TabItem>
    </TabControl>

    <StatusBar Grid.Row="3" Margin="0,6,0,0">
      <Grid Width="{Binding ActualWidth, RelativeSource={RelativeSource AncestorType=StatusBar}}">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="StatusText" Grid.Column="0" Text="Bereit." VerticalAlignment="Center"/>
        <TextBlock x:Name="HitCountText" Grid.Column="1" Text="Gefundene Mails: 0"
                   Margin="20,0,12,0" FontWeight="SemiBold" VerticalAlignment="Center"/>
      </Grid>
    </StatusBar>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$Window = [Windows.Markup.XamlReader]::Load($reader)

# Bind named controls to variables.
$names = @(
    'SearchPanel',
    'FromDate','FromTime','ToDate','ToTime','TimePresetBox','DirectionBox','MaxResultsBox','SenderBox','RecipientBox','AddressExactBox','AddressContainsBox',
    'SubjectBox','ResetButton','SearchButton','StatusList','SelectAllStatusButton','SelectNoStatusButton','AttachmentRejectOnlyBox','ResultGrid','DetailTabs',
    'OverviewGrid','AddressGrid','AttachmentWarningBorder','AttachmentWarning',
    'AttachmentGrid','AttachmentDetailGrid','ActionGrid','FilterGrid','ActivityGrid',
    'DeliveryGrid','RawText','StatusText','HitCountText'
)
foreach ($n in $names) {
    Set-Variable -Name $n -Value $Window.FindName($n) -Scope Script
}

# ------------------------- Initial state -------------------------

$now = Get-Date
$FromDate.SelectedDate = $now.Date.AddMinutes(-30)
$FromTime.Text          = $now.AddMinutes(-30).ToString('HH:mm')
$ToDate.SelectedDate   = $now.Date
$ToTime.Text            = $now.ToString('HH:mm')
$TimePresetBox.SelectedIndex = 1
$DirectionBox.SelectedIndex = 0
$MaxResultsBox.SelectedIndex = 1

$statusDefinitions = @(
    @('Erfolgreich','Success'),
    @('Zustellung ausstehend','DeliveryPending'),
    @('Zustellfehler','DispatcherError'),
    @('Permanent abgewiesen','PermanentlyBlocked'),
    @('Temporär abgewiesen','TemporarilyBlocked'),
    @('Angenommen aber nicht zugestellt','Suppressed'),
    @('Mehrere Zustellzustände','PartialSuccess'),
    @('Doppelt','DuplicateDrop'),
    @('Angehalten','PutOnHold')
)
foreach ($d in $statusDefinitions) {
    [void]$StatusList.Children.Add((New-StatusItem $d[0] $d[1]))
}

$SelectAllStatusButton.Add_Click({
    foreach ($item in $StatusList.Children) {
        if ($item -is [System.Windows.Controls.CheckBox]) {
            $item.IsChecked = $true
        }
    }
})

$SelectNoStatusButton.Add_Click({
    foreach ($item in $StatusList.Children) {
        if ($item -is [System.Windows.Controls.CheckBox]) {
            $item.IsChecked = $false
        }
    }
})

function Set-AttachmentRejectStatusSelection {
    param([bool]$Enabled)

    if ($Enabled) {
        foreach ($item in $StatusList.Children) {
            if ($item -is [System.Windows.Controls.CheckBox]) {
                $item.IsChecked = ([string]$item.Tag -eq 'PermanentlyBlocked')
            }
        }
    }
}

$AttachmentRejectOnlyBox.Add_Checked({
    Set-AttachmentRejectStatusSelection -Enabled $true
})

$AttachmentRejectOnlyBox.Add_Unchecked({
    # Restore the normal default: all delivery states selected.
    foreach ($item in $StatusList.Children) {
        if ($item -is [System.Windows.Controls.CheckBox]) {
            $item.IsChecked = $true
        }
    }
})

$script:Connected = $true
$script:CurrentTracks = @()
$script:CurrentDetail = $null
$StatusText.Text = 'Bei NoSpamProxy angemeldet. Bereit.'

# Ctrl+C in a DataGrid: copy only the value of the currently focused cell.
# Full-row selection remains unchanged so detail loading continues to work.
$Window.Add_PreviewKeyDown({
    param($sender, $e)

    if ($e.Key -ne [System.Windows.Input.Key]::C -or
        -not ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
        return
    }

    $element = [System.Windows.Input.Keyboard]::FocusedElement
    if ($null -eq $element) { return }

    # Walk up the visual tree to the DataGridCell.
    $cell = $element
    while ($null -ne $cell -and -not ($cell -is [System.Windows.Controls.DataGridCell])) {
        try { $cell = [System.Windows.Media.VisualTreeHelper]::GetParent($cell) }
        catch { $cell = $null }
    }
    if ($null -eq $cell) { return }

    # Find the owning DataGrid.
    $grid = $cell
    while ($null -ne $grid -and -not ($grid -is [System.Windows.Controls.DataGrid])) {
        try { $grid = [System.Windows.Media.VisualTreeHelper]::GetParent($grid) }
        catch { $grid = $null }
    }
    if ($null -eq $grid) { return }

    $item = $cell.DataContext
    $column = $cell.Column
    if ($null -eq $item -or $null -eq $column) { return }

    $value = $null

    # DataGridTextColumn: evaluate its Binding.Path against the row object.
    if ($column -is [System.Windows.Controls.DataGridBoundColumn]) {
        $binding = $column.Binding
        if ($null -ne $binding -and $null -ne $binding.Path) {
            $path = [string]$binding.Path.Path
            if (-not [string]::IsNullOrWhiteSpace($path)) {
                $prop = $item.PSObject.Properties[$path]
                if ($null -ne $prop) {
                    $value = $prop.Value
                }
            }
        }
    }

    # Auto-generated/fallback columns: use the displayed TextBlock/TextBox content.
    if ($null -eq $value) {
        $content = $cell.Content
        if ($content -is [System.Windows.Controls.TextBlock]) {
            $value = $content.Text
        }
        elseif ($content -is [System.Windows.Controls.TextBox]) {
            $value = $content.Text
        }
        elseif ($null -ne $content) {
            $value = [string]$content
        }
    }

    if ($null -eq $value) { $value = '' }

    [System.Windows.Clipboard]::SetText([string]$value)
    $e.Handled = $true
})

# ------------------------- Time range -------------------------

$script:ApplyingTimePreset = $false

function Set-TimeRangePreset {
    param([string]$Tag)
    if ([string]::IsNullOrWhiteSpace($Tag) -or $Tag -eq 'Custom') { return }

    $end = Get-Date
    switch ($Tag) {
        '30m' { $start = $end.AddMinutes(-30) }
        '1h'  { $start = $end.AddHours(-1) }
        '2h'  { $start = $end.AddHours(-2) }
        '6h'  { $start = $end.AddHours(-6) }
        '12h' { $start = $end.AddHours(-12) }
        '24h' { $start = $end.AddHours(-24) }
        '2d'  { $start = $end.AddDays(-2) }
        '7d'  { $start = $end.AddDays(-7) }
        '14d' { $start = $end.AddDays(-14) }
        '30d' { $start = $end.AddDays(-30) }
        '60d' { $start = $end.AddDays(-60) }
        '90d' { $start = $end.AddDays(-90) }
        default { return }
    }

    $script:ApplyingTimePreset = $true
    try {
        $FromDate.SelectedDate = $start.Date
        $FromTime.Text = $start.ToString('HH:mm')
        $ToDate.SelectedDate = $end.Date
        $ToTime.Text = $end.ToString('HH:mm')
    } finally {
        $script:ApplyingTimePreset = $false
    }
}

$TimePresetBox.Add_SelectionChanged({
    $item = $TimePresetBox.SelectedItem
    if ($null -ne $item) { Set-TimeRangePreset ([string]$item.Tag) }
})

# Manual date/time changes mean an individually adjusted range.
$markCustom = {
    if (-not $script:ApplyingTimePreset -and $null -ne $TimePresetBox -and $TimePresetBox.SelectedIndex -gt 0) {
        $TimePresetBox.SelectedIndex = 0
    }
}
$FromDate.Add_SelectedDateChanged($markCustom)
$ToDate.Add_SelectedDateChanged($markCustom)
$FromTime.Add_TextChanged($markCustom)
$ToTime.Add_TextChanged($markCustom)


# ------------------------- Reset -------------------------

$ResetButton.Add_Click({
    $now = Get-Date

    $FromDate.SelectedDate = $now.Date
    $FromTime.Text          = $now.AddMinutes(-30).ToString('HH:mm')
    $ToDate.SelectedDate   = $now.Date
    $ToTime.Text            = $now.ToString('HH:mm')

    $TimePresetBox.SelectedIndex = 1       # seit 30 Minuten
    $DirectionBox.SelectedIndex  = 0       # Alle
    $MaxResultsBox.SelectedIndex = 1

    $SenderBox.Clear()
    $RecipientBox.Clear()
    $SubjectBox.Clear()

    $AddressExactBox.IsChecked    = $true
    $AddressContainsBox.IsChecked = $false
    $AttachmentRejectOnlyBox.IsChecked = $false

    foreach ($item in $StatusList.Children) {
        $item.IsChecked = $true
    }

    $ResultGrid.ItemsSource = $null
    $HitCountText.Text = 'Gefundene Mails: 0'
    $script:CurrentTracks = @()
    $script:CurrentDetail = $null

    $OverviewGrid.ItemsSource = $null
    $AddressGrid.ItemsSource = $null
    $AttachmentGrid.ItemsSource = $null
    $AttachmentDetailGrid.ItemsSource = $null
    $ActionGrid.ItemsSource = $null
    $FilterGrid.ItemsSource = $null
    $ActivityGrid.ItemsSource = $null
    $DeliveryGrid.ItemsSource = $null
    $RawText.Text = ''
    $AttachmentWarningBorder.Visibility = 'Collapsed'
    $AttachmentWarning.Text = ''

    $StatusText.Text = 'Suche auf Standardwerte zurückgesetzt.'
})

# ------------------------- Search -------------------------

$SearchButton.Add_Click({
    try {
        $SearchButton.IsEnabled = $false
        $ResultGrid.ItemsSource = $null
        $HitCountText.Text = 'Gefundene Mails: 0'
        $StatusText.Text = 'Suche läuft \u2026'
        $Window.Cursor = [System.Windows.Input.Cursors]::Wait

        $from = $null
        $to = $null
        $timeFormat = 'HH:mm'
        $culture = [System.Globalization.CultureInfo]::InvariantCulture

        if ($null -ne $FromDate.SelectedDate) {
            $parsedFromTime = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($FromTime.Text.Trim(), $timeFormat, $culture, [System.Globalization.DateTimeStyles]::None, [ref]$parsedFromTime)) {
                throw 'Ungültige Von-Uhrzeit. Bitte HH:mm verwenden, z. B. 08:30.'
            }
            $fromDateValue = [datetime]$FromDate.SelectedDate
            $from = $fromDateValue.Date.Add($parsedFromTime.TimeOfDay)
        }
        if ($null -ne $ToDate.SelectedDate) {
            $parsedToTime = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($ToTime.Text.Trim(), $timeFormat, $culture, [System.Globalization.DateTimeStyles]::None, [ref]$parsedToTime)) {
                throw 'Ungültige Bis-Uhrzeit. Bitte HH:mm verwenden, z. B. 17:00.'
            }
            $toDateValue = [datetime]$ToDate.SelectedDate
            $to = $toDateValue.Date.Add($parsedToTime.TimeOfDay)
        }
        if ($null -ne $from -and $null -ne $to -and $from -gt $to) {
            throw '"Von" darf nicht nach "Bis" liegen.'
        }

        $common = @{
            WithAddresses        = $true
            WithAttachments      = $true
            WithActions          = $true
            WithFilters          = $true
            WithOperations       = $true
            WithDeliveryAttempts = $true
            WithLevelOfTrust     = $true
            WithTlsSettings      = $true
            First                = [uint64]100
        }

        if ($null -ne $from) { $common.From = [datetime]$from }
        if ($null -ne $to)   { $common.To = [datetime]$to }

        if (-not [string]::IsNullOrWhiteSpace($SubjectBox.Text)) {
            $common.Subject = $SubjectBox.Text.Trim()
        }

        $dirItem = $DirectionBox.SelectedItem
        $selectedDirection = if ($null -ne $dirItem) { [string]$dirItem.Tag } else { '' }

        # MessageTrack result objects in NSP 16.1 do not expose their direction.
        # Therefore query the directions separately and carry the query direction
        # into each result row.
        $queryDirections = if (-not [string]::IsNullOrWhiteSpace($selectedDirection)) {
            @($selectedDirection)
        } else {
            @('FromExternal','FromLocal')
        }

        # NSP exposes address searching as Between1/Between2. Wildcards are supported:
        # exact mode passes the address unchanged; contains mode wraps each value in *...*.
        # Between1/Between2 search across the participating message addresses, matching
        # NoSpamProxy's common sender/recipient address search behavior.
        $sender = $SenderBox.Text.Trim()
        $recipient = $RecipientBox.Text.Trim()
        $containsAddress = ($AddressContainsBox.IsChecked -eq $true)

        if ($containsAddress) {
            if ($sender)    { $sender    = '*' + $sender.Trim('*')    + '*' }
            if ($recipient) { $recipient = '*' + $recipient.Trim('*') + '*' }
        }

        if ($sender) { $common.Between1 = $sender }
        if ($recipient) {
            if ($sender) { $common.Between2 = $recipient }
            else { $common.Between1 = $recipient }
        }

        $attachmentRejectOnly = ($AttachmentRejectOnlyBox.IsChecked -eq $true)

        $statuses = @(Get-SelectedStatuses)
        if ($attachmentRejectOnly) {
            # Attachment-policy rejections are permanent rejections in the observed NSP data.
            # Query those server-side, then verify ContentFiltering below.
            $statuses = @('PermanentlyBlocked')
        }
        elseif ($statuses.Count -eq 9) {
            $statuses = @('All')
        }

        $maxItem = $MaxResultsBox.SelectedItem
        [int]$maxResults = if ($null -ne $maxItem) { [int]$maxItem.Tag } else { 250 }

        # DeliveryStatusQueryTypes may support combining enum values. To stay robust
        # across NSP builds, query each selected status separately and deduplicate.
        $queryStatusSets = if ($statuses.Count -gt 0) { $statuses } else { @($null) }

        $all = New-Object System.Collections.ArrayList
        $seen = @{}

        foreach ($queryDirection in $queryDirections) {
            $directionCount = 0
            foreach ($status in $queryStatusSets) {
                [uint64]$skip = 0
                while ($directionCount -lt $maxResults) {
                    $p = @{} + $common
                    $p.Directions = $queryDirection
                    $p.Skip = $skip
                    $p.First = [uint64][Math]::Min(100, ($maxResults - $directionCount))
                    if ($null -ne $status) { $p.Status = $status }

                    $batch = @(Get-NspMessageTrack @p)
                    if ($batch.Count -eq 0) { break }

                    foreach ($track in $batch) {
                        if ($attachmentRejectOnly) {
                            $attachmentPolicyReject = $false

                            foreach ($action in @(Get-PropValue $track 'Actions')) {
                                $actionName = [string](Get-PropValue $action 'Name')
                                $decision   = [string](Get-PropValue $action 'Decision')
                                $message    = [string](Get-PropValue $action 'Message')
                                $errorMsg   = [string](Get-PropValue $action 'ErrorMessage')
                                $combined   = ($message + ' ' + $errorMsg)

                                if ($actionName -eq 'ContentFiltering' -and
                                    $decision -match '^Reject' -and
                                    $combined -match '(?i)\battachment\b|\banhang\b|\banhänge\b') {
                                    $attachmentPolicyReject = $true
                                    break
                                }
                            }

                            if (-not $attachmentPolicyReject) { continue }
                        }

                        $id = [string](Get-PropValue $track 'Id')
                        if (-not $seen.ContainsKey($id)) {
                            $seen[$id] = $true
                            [void]$all.Add([pscustomobject]@{
                                Track = $track
                                DirectionText = Convert-Direction $queryDirection
                            })
                            $directionCount++
                            if ($directionCount -ge $maxResults) { break }
                        }
                    }

                    if ($batch.Count -lt [int]$p.First) { break }
                    $skip += [uint64]$batch.Count
                }
                if ($directionCount -ge $maxResults) { break }
            }
        }

        # Both directions have now been queried. Apply MaxResults only after
        # merging them, so a busy inbound direction cannot suppress outbound
        # results.
        $script:CurrentTracks = @(
            $all |
                Sort-Object { $_.Track.Sent } -Descending |
                Select-Object -First $maxResults
        )

        $rows = New-Object System.Collections.ArrayList
        foreach ($queryResult in $script:CurrentTracks) {
            $t = $queryResult.Track
            $sent = Get-PropValue $t 'Sent'
            $status = Get-PropValue $t 'Status'
            [void]$rows.Add([pscustomobject]@{
                SentText        = if ($sent) { ([datetimeoffset]$sent).LocalDateTime.ToString('dd.MM.yyyy HH:mm:ss') } else { '\u2014' }
                StatusText      = Convert-Status $status
                DirectionText   = $queryResult.DirectionText
                Sender          = Get-AddressValue $t 'Sender'
                HeaderFrom      = Get-AddressValue $t 'HeaderFrom'
                Recipient       = Get-AddressValue $t 'Recipient'
                Subject         = Format-Nullable (Get-PropValue $t 'Subject')
                AttachmentCount = @((Get-PropValue $t 'Attachments')).Count
                Track           = $t
            })
        }

        $ResultGrid.ItemsSource = @($rows)
        $HitCountText.Text = "Gefundene Mails: $($rows.Count)"
        if ($attachmentRejectOnly) {
            $StatusText.Text = "$($rows.Count) wegen Anhängen abgelehnte Nachricht(en) gefunden."
        } else {
            $StatusText.Text = "$($rows.Count) Nachricht(en) gefunden."
        }
    }
    catch {
        $StatusText.Text = 'Fehler bei der Suche.'
        Show-Error $_.Exception.Message 'Message Tracking'
    }
    finally {
        $Window.Cursor = [System.Windows.Input.Cursors]::Arrow
        $SearchButton.IsEnabled = $true
    }
})

# ------------------------- Lazy detail loading -------------------------

$ResultGrid.Add_SelectionChanged({
    $row = $ResultGrid.SelectedItem
    if ($null -eq $row) { return }

    try {
        $Window.Cursor = [System.Windows.Input.Cursors]::Wait
        $StatusText.Text = 'Details werden geladen \u2026'

        $baseTrack = $row.Track
        $mailId = Get-PropValue $baseTrack 'MailId'

        # The expanded collections are requested directly by Get-NspMessageTrack.
        # This is more reliable than passing the returned track into the individual
        # detail cmdlets, which can return empty collections in NSP 16.1.
        $detailTrack = $baseTrack

        $attachments = @(Get-PropValue $detailTrack 'Attachments')
        $actions     = @(Get-PropValue $detailTrack 'Actions')
        $filters     = @(Get-PropValue $detailTrack 'Filters')
        $operations  = @(Get-PropValue $detailTrack 'Operations')
        $activities  = @()

        $script:CurrentDetail = [pscustomobject]@{
            Track       = $detailTrack
            Attachments = $attachments
            Actions     = $actions
            Filters     = $filters
            Operations  = $operations
            Activities  = $activities
        }

        # Overview
        $overview = [ordered]@{
            'Empfangszeit'          = Get-PropValue $detailTrack 'Sent'
            'Mail-ID'               = Get-PropValue $detailTrack 'MailId'
            'Message-ID'            = Get-PropValue $detailTrack 'MessageId'
            'Betreff'               = Get-PropValue $detailTrack 'Subject'
            'Größe'                 = Format-Bytes (Get-PropValue $detailTrack 'Size')
            'SMTP-Absender'         = Get-AddressValue $detailTrack 'Sender'
            'Header-Absender'       = Get-AddressValue $detailTrack 'HeaderFrom'
            'Empfänger'             = Get-AddressValue $detailTrack 'Recipient'
            'Status'                = Convert-Status (Get-PropValue $detailTrack 'Status')
            'Status (NSP)'          = Get-PropValue $detailTrack 'Status'
            'Validierung'           = Get-PropValue $detailTrack 'ValidationStatus'
            'Ablehnungsgrund'       = Get-PropValue $detailTrack 'RejectReason'
            'SCL'                   = Get-PropValue $detailTrack 'Scl'
            'Regel'                 = Get-PropValue $detailTrack 'RuleName'
            'Client-IP'             = Get-PropValue $detailTrack 'ClientIPAddress'
            'Receive Connector'     = Get-PropValue $detailTrack 'ReceiveConnectorName'
            'Gateway'               = Get-PropValue $detailTrack 'ProcessingGatewayRole'
            'Von Relay empfangen'   = Get-PropValue $detailTrack 'WasReceivedFromRelayServer'
            'Bearbeitungsdauer'     = Format-Duration (Get-PropValue $detailTrack 'ProcessingTime')
            'Erster Zustellversuch' = Get-PropValue $detailTrack 'FirstDeliveryAttempt'
            'Zustelldauer'          = Format-Duration (Get-PropValue $detailTrack 'DeliveryDuration')
            'Signiert'              = Get-PropValue $detailTrack 'Signed'
            'Verschlüsselt'         = Get-PropValue $detailTrack 'Encrypted'
            'TLS-Protokoll'         = Get-PropValue $detailTrack 'TlsProtocol'
            'TLS-Cipher'            = Get-PropValue $detailTrack 'TlsCipherSuite'
            'Zertifikatstatus'      = Get-PropValue $detailTrack 'SenderCertificateValidationFlags'
            'Details gelöscht'      = Get-PropValue $detailTrack 'DetailsWereDeleted'
            'URL-Safeguard gelöscht'= Get-PropValue $detailTrack 'UrlSafeguardInfoWasDeleted'
            'Interne Track-ID'      = Get-PropValue $detailTrack 'Id'
        }
        $OverviewGrid.ItemsSource = New-PropertyRows $overview

        # Addresses
        $AddressGrid.ItemsSource = @(Get-PropValue $detailTrack 'Addresses')

        # Attachments / AttachmentManagement
        # NSP records the historical content-filter decision in Operation.Data
        # for operations of type AttachmentManagement. This lets us identify the
        # exact attachment and action that caused a rejection, even when the
        # normal Attachments collection is empty.
        $attachmentManagement = @()

        foreach ($opLink in $operations) {
            $op = Get-PropValue $opLink 'Operation'
            if ($null -eq $op) { continue }
            if ([string](Get-PropValue $op 'Type') -ne 'AttachmentManagement') { continue }

            $json = [string](Get-PropValue $op 'Data')
            if ([string]::IsNullOrWhiteSpace($json)) { continue }

            try {
                $am = $json | ConvertFrom-Json -ErrorAction Stop
                foreach ($amAction in @($am.actions)) {
                    if ($null -eq $amAction) { continue }

                    $recipientText = @(
                        foreach ($r in @($amAction.recipients)) {
                            if ($null -eq $r) { continue }
                            $lp = [string]$r.localPart
                            $dm = [string]$r.domain
                            if (-not [string]::IsNullOrWhiteSpace($lp) -and
                                -not [string]::IsNullOrWhiteSpace($dm)) {
                                "$lp@$dm"
                            }
                            elseif (-not [string]::IsNullOrWhiteSpace($lp)) { $lp }
                            elseif (-not [string]::IsNullOrWhiteSpace($dm)) { $dm }
                        }
                    ) -join '; '

                    $attachmentManagement += [pscustomobject]@{
                        FileName                    = [string]$amAction.filename
                        ActionName                  = [string]$amAction.action.name
                        ActionType                  = [string]$amAction.action.actionType
                        MailWasBlocked              = $am.mailWasBlocked
                        MailWasPutOnHold            = $amAction.mailWasPutOnHold
                        IsContentDisarmed           = $amAction.isContentDisarmed
                        IsAttachmentPasswordProtected = $amAction.isAttachmentPasswordProtected
                        Recipients                  = $recipientText
                        Raw                         = $amAction
                    }
                }
            }
            catch {
                # Keep the viewer usable if an older/different NSP version stores
                # an AttachmentManagement payload that cannot be parsed.
            }
        }

        # Resolve the effective inbound content-filter set from the SMTP sender.
        # NSP precedence: exact PartnerAddress -> Partner/domain -> DefaultPartnerSettings.
        $senderAddress = Get-AddressValue $detailTrack 'Sender'
        $effectiveFilter = $null
        if (-not [string]::IsNullOrWhiteSpace($senderAddress) -and $senderAddress -notmatch ';') {
            $effectiveFilter = Get-EffectiveInboundContentFilterSet $senderAddress
        }

        $attachmentRows = @()

        foreach ($a in $attachments) {
            $name = [string](Get-PropValue $a 'Name')
            $amInfo = @($attachmentManagement | Where-Object {
                [string]$_.FileName -eq $name
            } | Select-Object -First 1)

            $mime = [string](Get-PropValue $a 'MimeType')
            $resolvedEntry = $null
            if ($null -ne $effectiveFilter -and -not [string]::IsNullOrWhiteSpace($effectiveFilter.SetName)) {
                $resolvedEntry = Resolve-ContentFilterEntry $effectiveFilter.SetName $name $mime
            }

            $attachmentRows += [pscustomobject]@{
                Name             = $name
                MimeType         = $mime
                SizeText         = Format-Bytes (Get-PropValue $a 'Size')
                QuarantineText   = Format-Nullable (Get-PropValue $a 'IsQuarantined')
                MalwareText      = if ((Get-PropValue $a 'MalwareScanFailed') -eq $true) {
                                      'Fehlgeschlagen'
                                   } elseif ((Get-PropValue $a 'IsMalwareScanScheduled') -eq $true) {
                                      'Geplant'
                                   } elseif ((Get-PropValue $a 'IsMalwareScanScheduled') -eq $false) {
                                      'Nicht geplant'
                                   } else { '\u2014' }
                FilterSet        = if ($null -ne $effectiveFilter) { Format-Nullable $effectiveFilter.SetName } else { '\u2014' }
                FilterEntry      = if ($null -ne $resolvedEntry) { Format-Nullable $resolvedEntry.EntryName } else { '\u2014' }
                FilterSource     = if ($null -ne $effectiveFilter) { Format-Nullable $effectiveFilter.Source } else { '\u2014' }
                FilterResolution = $effectiveFilter
                ResolvedEntry    = $resolvedEntry
                FilterAction     = if ($amInfo.Count -gt 0) { Format-Nullable $amInfo[0].ActionName } else { '\u2014' }
                FilterActionType = if ($amInfo.Count -gt 0) { Format-Nullable $amInfo[0].ActionType } else { '\u2014' }
                Attachment       = $a
                Management       = if ($amInfo.Count -gt 0) { $amInfo[0] } else { $null }
            }
        }

        # AttachmentManagement can still contain the rejected filename when the
        # regular Attachments collection is empty. Add such files as synthetic
        # rows so the rejection remains visible and selectable.
        foreach ($amInfo in $attachmentManagement) {
            $alreadyPresent = @($attachmentRows | Where-Object {
                [string]$_.Name -eq [string]$amInfo.FileName
            }).Count -gt 0

            if (-not $alreadyPresent) {
                $resolvedEntry = $null
                if ($null -ne $effectiveFilter -and -not [string]::IsNullOrWhiteSpace($effectiveFilter.SetName)) {
                    $resolvedEntry = Resolve-ContentFilterEntry $effectiveFilter.SetName ([string]$amInfo.FileName) $null
                }
                $attachmentRows += [pscustomobject]@{
                    Name             = $amInfo.FileName
                    MimeType         = '\u2014'
                    SizeText         = '\u2014'
                    QuarantineText   = '\u2014'
                    MalwareText      = '\u2014'
                    FilterSet        = if ($null -ne $effectiveFilter) { Format-Nullable $effectiveFilter.SetName } else { '\u2014' }
                    FilterEntry      = if ($null -ne $resolvedEntry) { Format-Nullable $resolvedEntry.EntryName } else { '\u2014' }
                    FilterSource     = if ($null -ne $effectiveFilter) { Format-Nullable $effectiveFilter.Source } else { '\u2014' }
                    FilterResolution = $effectiveFilter
                    ResolvedEntry    = $resolvedEntry
                    FilterAction     = Format-Nullable $amInfo.ActionName
                    FilterActionType = Format-Nullable $amInfo.ActionType
                    Attachment       = $null
                    Management       = $amInfo
                }
            }
        }

        $AttachmentGrid.ItemsSource = @($attachmentRows)
        $AttachmentDetailGrid.ItemsSource = $null

        # ContentFiltering rejection warning. Prefer the exact historical
        # AttachmentManagement information; fall back to the generic tracking
        # message for older/incomplete records.
        $rejectActions = @($actions | Where-Object {
            ([string](Get-PropValue $_ 'Decision') -match '^Reject') -or
            (-not [string]::IsNullOrWhiteSpace([string](Get-PropValue $_ 'ErrorMessage')))
        })
        $contentReject = @($rejectActions | Where-Object {
            [string](Get-PropValue $_ 'Name') -eq 'ContentFiltering'
        } | Select-Object -First 1)

        $blockingAttachments = @($attachmentManagement | Where-Object {
            ([string]$_.ActionType -eq 'Block') -or ($_.MailWasBlocked -eq $true)
        })

        if ($blockingAttachments.Count -gt 0) {
            $warningLines = @()
            foreach ($b in $blockingAttachments) {
                $line = 'Die Nachricht wurde aufgrund des Anhangs "' + (Format-Nullable $b.FileName) + '" abgewiesen.'
                if (-not [string]::IsNullOrWhiteSpace([string]$b.ActionName) -or
                    -not [string]::IsNullOrWhiteSpace([string]$b.ActionType)) {
                    $line += ' Content-Filteraktion: ' +
                             (Format-Nullable $b.ActionName) +
                             ' (' + (Format-Nullable $b.ActionType) + ').'
                }
                $rowInfo = @($attachmentRows | Where-Object { [string]$_.Name -eq [string]$b.FileName } | Select-Object -First 1)
                if ($rowInfo.Count -gt 0 -and $rowInfo[0].FilterSet -ne '\u2014') {
                    $line += ' Inhaltsfilter: ' + $rowInfo[0].FilterSet + '.'
                    if ($rowInfo[0].FilterEntry -ne '\u2014') { $line += ' Filtereintrag: ' + $rowInfo[0].FilterEntry + '.' }
                    if ($rowInfo[0].FilterSource -ne '\u2014') { $line += ' Herkunft: ' + $rowInfo[0].FilterSource + '.' }
                }
                $warningLines += $line
            }
            $AttachmentWarning.Text = ($warningLines -join "`n")
            $AttachmentWarningBorder.Visibility = 'Visible'
        }
        elseif ($contentReject.Count -gt 0) {
            $msg = Format-Nullable (Get-PropValue $contentReject[0] 'Message')
            $AttachmentWarning.Text =
                "Die Nachricht wurde durch Content Filtering abgelehnt: $msg`n" +
                "Für diese Nachricht enthalten die vorliegenden Tracking-Daten keine auswertbare AttachmentManagement-Zuordnung zu einem einzelnen Anhang."
            $AttachmentWarningBorder.Visibility = 'Visible'
        }
        else {
            $AttachmentWarningBorder.Visibility = 'Collapsed'
            $AttachmentWarning.Text = ''
        }

        # Actions
        $ActionGrid.ItemsSource = @(
            foreach ($a in $actions) {
                [pscustomobject]@{
                    Name         = Get-PropValue $a 'Name'
                    Decision     = Get-PropValue $a 'Decision'
                    TimeText     = Format-Duration (Get-PropValue $a 'Time')
                    Message      = Get-PropValue $a 'Message'
                    ErrorMessage = Get-PropValue $a 'ErrorMessage'
                }
            }
        )

        # Filters
        $FilterGrid.ItemsSource = @(
            foreach ($f in $filters) {
                [pscustomobject]@{
                    Name         = Get-PropValue $f 'Name'
                    Scl          = Get-PropValue $f 'Scl'
                    TimeText     = Format-Duration (Get-PropValue $f 'Time')
                    Message      = Get-PropValue $f 'Message'
                    ErrorMessage = Get-PropValue $f 'ErrorMessage'
                }
            }
        )

        $ActivityGrid.ItemsSource = @(
            foreach ($op in $operations) {
                [pscustomobject]@{
                    Zeitpunkt  = Get-PropValue $op 'Created'
                    OperationId = Get-PropValue $op 'OperationId'
                    Id          = Get-PropValue $op 'Id'
                    Operation   = Format-Nullable (Get-PropValue $op 'Operation')
                }
            }
        )
        $DeliveryGrid.ItemsSource = @(Get-PropValue $detailTrack 'DeliveryAttempts')

        $RawText.Text = @"
MESSAGE TRACK
=============
$(Convert-ToRawText $detailTrack)

ADDRESSES
=========
$(Convert-ToRawText (Get-PropValue $detailTrack 'Addresses'))

ATTACHMENTS
===========
$(Convert-ToRawText $attachments)

ACTIONS
=======
$(Convert-ToRawText $actions)

FILTERS
=======
$(Convert-ToRawText $filters)

PROCESSING OPERATIONS
=====================
$(Convert-ToRawText $operations)

ATTACHMENT MANAGEMENT
=====================
$(Convert-ToRawText $attachmentManagement)

DELIVERY ATTEMPTS
=================
$(Convert-ToRawText (Get-PropValue $detailTrack 'DeliveryAttempts'))


LEVEL OF TRUST
==============
$(Convert-ToRawText (Get-PropValue $detailTrack 'LevelOfTrust'))
"@

        $StatusText.Text = "Details für Mail-ID $mailId geladen."
    }
    catch {
        $StatusText.Text = 'Fehler beim Laden der Details.'
        Show-Error $_.Exception.Message 'Nachrichtendetails'
    }
    finally {
        $Window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }
})

$AttachmentGrid.Add_SelectionChanged({
    $row = $AttachmentGrid.SelectedItem
    if ($null -eq $row) {
        $AttachmentDetailGrid.ItemsSource = $null
        return
    }

    $a  = $row.Attachment
    $am = $row.Management

    $props = [ordered]@{
        'Dateiname'                = $row.Name
        'Größe'                    = if ($null -ne $a) { Format-Bytes (Get-PropValue $a 'Size') } else { '\u2014' }
        'Größe (Bytes)'            = if ($null -ne $a) { Get-PropValue $a 'Size' } else { $null }
        'MIME-Type'                = if ($null -ne $a) { Get-PropValue $a 'MimeType' } else { $null }
        'SHA-256'                  = if ($null -ne $a) { Get-PropValue $a 'Sha256Hash' } else { $null }
        'TLSH'                     = if ($null -ne $a) { Get-PropValue $a 'TlshHash' } else { $null }
        'Speicherort'              = if ($null -ne $a) { Get-PropValue $a 'Location' } else { $null }
        'Folder-ID'                = if ($null -ne $a) { Get-PropValue $a 'FolderId' } else { $null }
        'Quarantäne'               = if ($null -ne $a) { Get-PropValue $a 'IsQuarantined' } else { $null }
        'Malware-Scan geplant'     = if ($null -ne $a) { Get-PropValue $a 'IsMalwareScanScheduled' } else { $null }
        'Letzter Malware-Scan'     = if ($null -ne $a) { Get-PropValue $a 'LastMalwareScan' } else { $null }
        'Malware-Scan Fehler'      = if ($null -ne $a) { Get-PropValue $a 'MalwareScanFailed' } else { $null }
        'Auto-Freigabedatum'       = if ($null -ne $a) { Get-PropValue $a 'AutoApprovalDate' } else { $null }
        'Freigabe angefordert von' = if ($null -ne $a) { Get-PropValue $a 'ApprovalRequestedBy' } else { $null }
        'Freigabe angefordert am'  = if ($null -ne $a) { Get-PropValue $a 'ApprovalRequestedOn' } else { $null }
        'Freigabegrund'            = if ($null -ne $a) { Get-PropValue $a 'ApprovalRequestReason' } else { $null }
        'Freigegeben von'          = if ($null -ne $a) { Get-PropValue $a 'ApprovedBy' } else { $null }
        'Freigegeben am'           = if ($null -ne $a) { Get-PropValue $a 'ApprovedOn' } else { $null }
        'Gelöscht von'             = if ($null -ne $a) { Get-PropValue $a 'DeletedBy' } else { $null }
        'Gelöscht am'              = if ($null -ne $a) { Get-PropValue $a 'DeletedOn' } else { $null }
        'Löschgrund'               = if ($null -ne $a) { Get-PropValue $a 'DeleteReason' } else { $null }
        'Download-Link verfügbar'  = if ($null -ne $a) { Get-PropValue $a 'IsDownloadLinkAvailable' } else { $null }
        'MessageTrack-ID'          = if ($null -ne $a) { Get-PropValue $a 'MessageTrackId' } else { $null }
        'Attachment-ID'            = if ($null -ne $a) { Get-PropValue $a 'Id' } else { $null }
        'Content-Filteraktion'     = if ($null -ne $am) { $am.ActionName } else { $null }
        'Inhaltsfilter'             = $row.FilterSet
        'Filterherkunft'            = $row.FilterSource
        'Filtereintrag'             = $row.FilterEntry
        'Adress-Einstellung'        = if ($null -ne $row.FilterResolution) { $row.FilterResolution.AddressSetting } else { $null }
        'Domain-Einstellung'        = if ($null -ne $row.FilterResolution) { $row.FilterResolution.DomainSetting } else { $null }
        'Standard-Einstellung'      = if ($null -ne $row.FilterResolution) { $row.FilterResolution.DefaultSetting } else { $null }
        'Content-Filter Aktionstyp'= if ($null -ne $am) { $am.ActionType } else { $null }
        'Mail blockiert'           = if ($null -ne $am) { $am.MailWasBlocked } else { $null }
        'Passwortgeschützt'        = if ($null -ne $am) { $am.IsAttachmentPasswordProtected } else { $null }
        'Content Disarm'           = if ($null -ne $am) { $am.IsContentDisarmed } else { $null }
        'Mail angehalten'          = if ($null -ne $am) { $am.MailWasPutOnHold } else { $null }
        'Betroffene Empfänger'     = if ($null -ne $am) { $am.Recipients } else { $null }
    }
    $AttachmentDetailGrid.ItemsSource = New-PropertyRows $props
})

[void]$Window.ShowDialog()
