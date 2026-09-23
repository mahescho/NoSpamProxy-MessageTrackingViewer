#requires -Version 5.1
<#
NoSpamProxy 16.1 Message Tracking Viewer
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
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return '—' }
    if ($Value -is [bool]) {
        if ($Value) { return 'Ja' } else { return 'Nein' }
    }
    return [string]$Value
}

function Format-Bytes {
    param($Bytes)
    if ($null -eq $Bytes -or "$Bytes" -eq '') { return '—' }
    [double]$n = $Bytes
    if ($n -ge 1GB) { return ('{0:N2} GB' -f ($n / 1GB)) }
    if ($n -ge 1MB) { return ('{0:N2} MB' -f ($n / 1MB)) }
    if ($n -ge 1KB) { return ('{0:N1} KB' -f ($n / 1KB)) }
    return ('{0:N0} Bytes' -f $n)
}

function Format-Duration {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return '—' }
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
        default                { if ("$Status") { [string]$Status } else { '—' } }
    }
}

function Convert-Direction {
    param($Direction)
    switch ([string]$Direction) {
        'FromExternal' { 'Eingehend' }
        'FromInternal' { 'Ausgehend' }
        'Inbound'      { 'Eingehend' }
        'Outbound'     { 'Ausgehend' }
        default        { if ("$Direction") { [string]$Direction } else { '—' } }
    }
}

function Convert-ToRawText {
    param($Object)
    if ($null -eq $Object) { return '—' }
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
        <DatePicker x:Name="FromDate" Grid.Row="0" Grid.Column="1" Margin="3"/>
        <TextBlock Grid.Row="0" Grid.Column="2" Text="Bis:" VerticalAlignment="Center" Margin="10,3,3,3"/>
        <DatePicker x:Name="ToDate" Grid.Row="0" Grid.Column="3" Margin="3"/>
        <TextBlock Grid.Row="0" Grid.Column="4" Text="Richtung:" VerticalAlignment="Center" Margin="10,3,3,3"/>
        <ComboBox x:Name="DirectionBox" Grid.Row="0" Grid.Column="5">
          <ComboBoxItem Content="Alle" Tag=""/>
          <ComboBoxItem Content="Eingehend" Tag="FromExternal"/>
          <ComboBoxItem Content="Ausgehend" Tag="FromInternal"/>
        </ComboBox>
        <TextBlock Grid.Row="0" Grid.Column="6" Text="Max. Treffer:" VerticalAlignment="Center" Margin="10,3,3,3"/>
        <ComboBox x:Name="MaxResultsBox" Grid.Row="0" Grid.Column="7">
          <ComboBoxItem Content="100" Tag="100"/>
          <ComboBoxItem Content="250" Tag="250"/>
          <ComboBoxItem Content="500" Tag="500"/>
          <ComboBoxItem Content="1000" Tag="1000"/>
        </ComboBox>

        <TextBlock Grid.Row="1" Grid.Column="0" Text="Absender:" VerticalAlignment="Center" Margin="3"/>
        <TextBox x:Name="SenderBox" Grid.Row="1" Grid.Column="1"/>
        <TextBlock Grid.Row="1" Grid.Column="2" Text="Empfänger:" VerticalAlignment="Center" Margin="10,3,3,3"/>
        <TextBox x:Name="RecipientBox" Grid.Row="1" Grid.Column="3"/>
        <TextBlock Grid.Row="1" Grid.Column="4" Text="Betreff:" VerticalAlignment="Center" Margin="10,3,3,3"/>
        <TextBox x:Name="SubjectBox" Grid.Row="1" Grid.Column="5" Grid.ColumnSpan="3"/>
        <Button x:Name="SearchButton" Grid.Row="1" Grid.Column="8" Content="Suchen" HorizontalAlignment="Right" MinWidth="110"/>

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
            <RowDefinition Height="2*"/>
            <RowDefinition Height="*"/>
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
    'FromDate','ToDate','DirectionBox','MaxResultsBox','SenderBox','RecipientBox',
    'SubjectBox','SearchButton','StatusList','SelectAllStatusButton','SelectNoStatusButton','AttachmentRejectOnlyBox','ResultGrid','DetailTabs',
    'OverviewGrid','AddressGrid','AttachmentWarningBorder','AttachmentWarning',
    'AttachmentGrid','AttachmentDetailGrid','ActionGrid','FilterGrid','ActivityGrid',
    'DeliveryGrid','RawText','StatusText','HitCountText'
)
foreach ($n in $names) {
    Set-Variable -Name $n -Value $Window.FindName($n) -Scope Script
}

# ------------------------- Initial state -------------------------

$FromDate.SelectedDate = (Get-Date).Date.AddDays(-1)
$ToDate.SelectedDate   = (Get-Date).Date
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

# ------------------------- Search -------------------------

$SearchButton.Add_Click({
    try {
        $SearchButton.IsEnabled = $false
        $ResultGrid.ItemsSource = $null
        $HitCountText.Text = 'Gefundene Mails: 0'
        $StatusText.Text = 'Suche läuft …'
        $Window.Cursor = [System.Windows.Input.Cursors]::Wait

        $from = $FromDate.SelectedDate
        $to = $ToDate.SelectedDate
        if ($null -ne $to) {
            # DatePicker "Bis" means inclusive entire day.
            $to = $to.Date.AddDays(1).AddTicks(-1)
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
        if ($null -ne $dirItem -and -not [string]::IsNullOrWhiteSpace([string]$dirItem.Tag)) {
            $common.Directions = [string]$dirItem.Tag
        }

        # NSP exposes address searching as Between1/Between2.
        # With both fields set, both are passed server-side. With only one, Between1 is used.
        $sender = $SenderBox.Text.Trim()
        $recipient = $RecipientBox.Text.Trim()
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

        foreach ($status in $queryStatusSets) {
            [uint64]$skip = 0
            while ($all.Count -lt $maxResults) {
                $p = @{} + $common
                $p.Skip = $skip
                $p.First = [uint64][Math]::Min(100, ($maxResults - $all.Count))
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

                        if (-not $attachmentPolicyReject) {
                            continue
                        }
                    }

                    $id = [string](Get-PropValue $track 'Id')
                    if (-not $seen.ContainsKey($id)) {
                        $seen[$id] = $true
                        [void]$all.Add($track)
                        if ($all.Count -ge $maxResults) { break }
                    }
                }

                if ($batch.Count -lt [int]$p.First) { break }
                $skip += [uint64]$batch.Count
            }
            if ($all.Count -ge $maxResults) { break }
        }

        $script:CurrentTracks = @($all)

        $rows = New-Object System.Collections.ArrayList
        foreach ($t in $script:CurrentTracks) {
            $sent = Get-PropValue $t 'Sent'
            $status = Get-PropValue $t 'Status'
            $direction = Get-PropValue $t 'Direction'
            if ($null -eq $direction) { $direction = Get-PropValue $t 'Directions' }

            [void]$rows.Add([pscustomobject]@{
                SentText        = if ($sent) { ([datetimeoffset]$sent).LocalDateTime.ToString('dd.MM.yyyy HH:mm:ss') } else { '—' }
                StatusText      = Convert-Status $status
                DirectionText   = Convert-Direction $direction
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
        $StatusText.Text = 'Details werden geladen …'

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

        # Attachments
        $attachmentRows = foreach ($a in $attachments) {
            [pscustomobject]@{
                Name           = Get-PropValue $a 'Name'
                MimeType       = Get-PropValue $a 'MimeType'
                SizeText       = Format-Bytes (Get-PropValue $a 'Size')
                QuarantineText = Format-Nullable (Get-PropValue $a 'IsQuarantined')
                MalwareText    = if ((Get-PropValue $a 'MalwareScanFailed') -eq $true) {
                                    'Fehlgeschlagen'
                                 } elseif ((Get-PropValue $a 'IsMalwareScanScheduled') -eq $true) {
                                    'Geplant'
                                 } elseif ((Get-PropValue $a 'IsMalwareScanScheduled') -eq $false) {
                                    'Nicht geplant'
                                 } else { '—' }
                Attachment     = $a
            }
        }
        $AttachmentGrid.ItemsSource = @($attachmentRows)
        $AttachmentDetailGrid.ItemsSource = $null

        # ContentFiltering rejection warning.
        $rejectActions = @($actions | Where-Object {
            ([string](Get-PropValue $_ 'Decision') -match '^Reject') -or
            (-not [string]::IsNullOrWhiteSpace([string](Get-PropValue $_ 'ErrorMessage')))
        })
        $contentReject = @($rejectActions | Where-Object {
            [string](Get-PropValue $_ 'Name') -eq 'ContentFiltering'
        } | Select-Object -First 1)

        if ($contentReject.Count -gt 0) {
            $msg = Format-Nullable (Get-PropValue $contentReject[0] 'Message')
            $AttachmentWarning.Text =
                "Die Nachricht wurde durch Content Filtering abgelehnt: $msg`n" +
                "NoSpamProxy weist in den vorliegenden Message-Tracking-Daten nicht aus, welcher einzelne Anhang die Ablehnung ausgelöst hat."
            $AttachmentWarningBorder.Visibility = 'Visible'
        } else {
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

    $a = $row.Attachment
    $props = [ordered]@{
        'Dateiname'             = Get-PropValue $a 'Name'
        'Größe'                 = Format-Bytes (Get-PropValue $a 'Size')
        'Größe (Bytes)'         = Get-PropValue $a 'Size'
        'MIME-Type'             = Get-PropValue $a 'MimeType'
        'SHA-256'               = Get-PropValue $a 'Sha256Hash'
        'TLSH'                  = Get-PropValue $a 'TlshHash'
        'Speicherort'           = Get-PropValue $a 'Location'
        'Folder-ID'             = Get-PropValue $a 'FolderId'
        'Quarantäne'            = Get-PropValue $a 'IsQuarantined'
        'Malware-Scan geplant'  = Get-PropValue $a 'IsMalwareScanScheduled'
        'Letzter Malware-Scan'  = Get-PropValue $a 'LastMalwareScan'
        'Malware-Scan Fehler'   = Get-PropValue $a 'MalwareScanFailed'
        'Auto-Freigabedatum'    = Get-PropValue $a 'AutoApprovalDate'
        'Freigabe angefordert von' = Get-PropValue $a 'ApprovalRequestedBy'
        'Freigabe angefordert am'  = Get-PropValue $a 'ApprovalRequestedOn'
        'Freigabegrund'         = Get-PropValue $a 'ApprovalRequestReason'
        'Freigegeben von'       = Get-PropValue $a 'ApprovedBy'
        'Freigegeben am'        = Get-PropValue $a 'ApprovedOn'
        'Gelöscht von'          = Get-PropValue $a 'DeletedBy'
        'Gelöscht am'           = Get-PropValue $a 'DeletedOn'
        'Löschgrund'            = Get-PropValue $a 'DeleteReason'
        'Download-Link verfügbar'= Get-PropValue $a 'IsDownloadLinkAvailable'
        'MessageTrack-ID'       = Get-PropValue $a 'MessageTrackId'
        'Attachment-ID'         = Get-PropValue $a 'Id'
    }
    $AttachmentDetailGrid.ItemsSource = New-PropertyRows $props
})

[void]$Window.ShowDialog()
