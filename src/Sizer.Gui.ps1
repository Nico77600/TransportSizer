<#
.SYNOPSIS
    Transport Sizer - graphical interface (dot-sourced by TransportSizer.psm1).

.DESCRIPTION
    WPF window that replaces the input sheet of the Excel calculator. With .NET 9 or later (PowerShell 7.5
    and later) it uses the Fluent theme of Windows 11, light or dark like Windows; with Windows PowerShell
    5.1 or PowerShell 7.4 the same window uses the classic controls with the colours of the report.

    Left: the scenario, card by card (role, topology, message flows in an editable grid, load, resilience,
    storage, compute and network, physical server, calibration). Right: the server sized for this scenario,
    recalculated a moment after every change (same engine as the command line), the target configuration
    and the checks. Bottom: new, open, save, and the HTML report that explains every number.

    Closing never needs PowerShell code: Close is the cancel button of the window (Esc too) and the
    title-bar button is native. Ctrl+C is ignored in the console while the window is open.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.10.0
#>

$script:Gui = $null
$script:TsGuiIconFont = 'Segoe Fluent Icons, Segoe MDL2 Assets'
$script:TsGuiRoles = @(
    [pscustomobject]@{ Role = 'Edge'; Title = 'Edge Transport'; Detail = 'Périmètre : file et réseau, sans Safety Net ni shadow'; Glyph = 0xE774 }
    [pscustomobject]@{ Role = 'Mailbox'; Title = 'Mailbox (transport)'; Detail = 'Avec ou sans boîtes : Safety Net et shadow'; Glyph = 0xE715 }
)
# Text boxes of the form: control name, place in the scenario, French label, tooltip.
$script:TsGuiFields = @(
    @{ Name = 'ScenarioName'; Key = 'Name'; Label = 'Nom du scénario'; Text = $true }
    @{ Name = 'Customer'; Key = 'Customer'; Label = 'Client'; Text = $true }
    @{ Name = 'Author'; Key = 'Author'; Label = 'Auteur'; Text = $true }
    @{ Name = 'ServersPerSite'; Group = 'Topology'; Key = 'ServersPerSite'; Label = 'Serveurs par site'; Tip = 'Serveurs de ce rôle dans chaque site (même nombre dans chaque site).' }
    @{ Name = 'Growth'; Group = 'Load'; Key = 'GrowthPercent'; Label = 'Croissance (%)'; Tip = 'Augmentation du trafic prévue sur la durée de vie des serveurs.' }
    @{ Name = 'PeakHour'; Group = 'Load'; Key = 'PeakHourPercent'; Label = 'Heure de pointe (% du jour)'; Tip = 'Part du trafic journalier dans chaque heure de pointe (avec 24 heures ouvrées, 4,2 % = trafic uniforme). Ignorée quand un débit de pointe mesuré est saisi.' }
    @{ Name = 'WorkingHours'; Group = 'Load'; Key = 'WorkingHours'; Label = 'Heures ouvrées par jour'; Tip = 'Heures pendant lesquelles passe l’’essentiel du trafic (journée de travail). 24 = trafic réparti sur toute la journée.' }
    @{ Name = 'OffHours'; Group = 'Load'; Key = 'OffHoursPercent'; Label = 'Trafic hors heures ouvrées (%)'; Tip = 'Part des messages du jour reçus en dehors des heures ouvrées (nuit, week-end ramené à la journée, traitements planifiés, Internet).' }
    @{ Name = 'PeakHours'; Group = 'Load'; Key = 'PeakHours'; Label = 'Durée de la pointe (h)'; Tip = 'Nombre d’’heures de la journée au niveau de la pointe (une ou deux heures en général) : il compte pour la file accumulée pendant une panne courte.' }
    @{ Name = 'PeakRate'; Group = 'Load'; Key = 'PeakRate'; Label = 'Débit de pointe mesuré (organisation)'; Tip = 'Débit de l’’heure la plus chargée pour toute l’’organisation, mesuré sur l’’existant (suivi des messages, Exchange Log Report), en messages par heure ou par seconde. 0 = part de l’’heure de pointe saisie à la place.' }
    @{ Name = 'Burst'; Group = 'Load'; Key = 'BurstFactor'; Label = 'Facteur de rafale'; Tip = 'Pointes de quelques minutes au-dessus de la moyenne de l’’heure de pointe. 1 = aucune.' }
    @{ Name = 'TransportRules'; Group = 'Load'; Key = 'TransportRules'; Label = 'Règles de transport'; Tip = 'Règles actives évaluées pour chaque message : règles Edge (Get-TransportRule sur l’’Edge) ou règles de l’’organisation (Mailbox).' }
    @{ Name = 'TlsPercent'; Group = 'Load'; Key = 'TlsPercent'; Label = 'Sessions en TLS (%)'; Tip = 'Part des sessions SMTP reçues en TLS (STARTTLS). Internet et serveurs Exchange : proche de 100 %.' }
    @{ Name = 'PerSession'; Group = 'Load'; Key = 'MessagesPerSession'; Label = 'Messages par session'; Tip = 'Messages reçus par session SMTP. Internet : 1 à 2 (une session par message pour la plupart des expéditeurs). Entre serveurs Exchange : davantage.' }
    @{ Name = 'Expiration'; Group = 'Resilience'; Key = 'MessageExpirationHours'; Label = 'Expiration des messages (h)'; Tip = 'MessageExpirationTimeout (Set-TransportService), 48 h par défaut : au-delà, un message en file est rendu à l’’expéditeur.' }
    @{ Name = 'Outage'; Group = 'Resilience'; Key = 'OutageHours'; Label = 'Panne du saut suivant (h)'; Tip = 'Durée pendant laquelle le saut suivant (Internet, Edge, serveurs de boîtes, relais) est injoignable : les messages des flux retenus s’’accumulent.' }
    @{ Name = 'Residence'; Group = 'Resilience'; Key = 'ResidenceSeconds'; Label = 'Séjour en transit (s)'; Tip = 'Durée moyenne d’’un message dans la file sans panne (loi de Little).' }
    @{ Name = 'ReclaimDays'; Group = 'Resilience'; Key = 'SpaceReclaimDays'; Label = 'Récupération de l’’espace (jours)'; Tip = 'Jours entre deux récupérations de l’’espace des messages remis dans mail.que : défragmentation en ligne quotidienne (QueueDatabaseOnlineDefragSchedule, 01:00) ou redémarrage du transport. Mesuré sur REF-EDGE : sans récupération, mail.que grossit avec tout le trafic traité. 0 = non compté.' }
    @{ Name = 'DrainTarget'; Group = 'Resilience'; Key = 'DrainTargetHours'; Label = 'Vidange visée (h)'; Tip = 'Délai pour renvoyer la file de la panne une fois le saut suivant revenu, tout en recevant le trafic des heures ouvrées : les processeurs sont dimensionnés pour le tenir. 0 = pas de condition.' }
    @{ Name = 'JournalPercent'; Group = 'Journaling'; Key = 'Percent'; Label = 'Part journalisée (%)'; Tip = 'Part des messages de la portée couverts par les règles de journal ou la journalisation standard (bases de boîtes concernées). 100 = tous.' }
    @{ Name = 'JournalRecipients'; Group = 'Journaling'; Key = 'Recipients'; Label = 'Destinations de journal'; Tip = 'Rapports écrits par message journalisé : une par boîte de journalisation ou archive distincte. Une règle « tous les messages » qui recoupe une règle interne ou externe en ajoute une.' }
    @{ Name = 'JournalOverhead'; Group = 'Journaling'; Key = 'OverheadKB'; Label = 'Enveloppe du rapport (Ko)'; Tip = 'Corps du rapport de journal : expéditeur, objet, Message-ID, liste des destinataires. Le message d’’origine est joint en plus, inchangé.' }
    @{ Name = 'SafetyNet'; Group = 'Resilience'; Key = 'SafetyNetHoldTimeHours'; Label = 'SafetyNetHoldTime (h)'; Tip = 'Set-TransportConfig -SafetyNetHoldTime, 48 h par défaut. Rôle Mailbox uniquement.' }
    @{ Name = 'ReplayLag'; Group = 'Resilience'; Key = 'ReplayLagHours'; Label = 'Délai de relecture (h)'; Tip = 'ReplayLagTime des copies décalées du DAG : Safety Net doit le couvrir. 0 sans copie décalée.' }
    @{ Name = 'MaxFill'; Group = 'Storage'; Key = 'MaxFillPercent'; Label = 'Remplissage maximal (%)'; Tip = 'Marge de conception des volumes. Le seuil de back pressure du volume s’’applique s’’il est plus bas (89 %).' }
    @{ Name = 'IoOverhead'; Group = 'Storage'; Key = 'IoOverheadPercent'; Label = 'Surcoût E/S (%)'; Tip = 'Marge sur les IOPS mesurées (20 % dans le calculateur Microsoft).' }
    @{ Name = 'OsGB'; Group = 'Storage'; Key = 'OsGB'; Label = 'Windows Server (Go)'; Tip = 'Système d’’exploitation et mises à jour (32 Go minimum pour Windows Server).' }
    @{ Name = 'BinariesGB'; Group = 'Storage'; Key = 'ExchangeBinariesGB'; Label = 'Binaires Exchange (Go)'; Tip = 'Dossier d’’installation d’’Exchange.' }
    @{ Name = 'DiagnosticGB'; Group = 'Storage'; Key = 'DiagnosticLogsGB'; Label = 'Journaux de diagnostic (Go)'; Tip = 'Logging\Diagnostics, Monitoring et, sur Mailbox, journaux IIS.' }
    @{ Name = 'TransportLogsGB'; Group = 'Storage'; Key = 'TransportLogsGB'; Label = 'Journaux de transport (Go)'; Tip = 'Somme des *MaxDirectorySize de Get-TransportService (suivi des messages, protocole, connectivité…).' }
    @{ Name = 'OtherDataGB'; Group = 'Storage'; Key = 'OtherTransportDataGB'; Label = 'Autres données (Go)'; Tip = 'TransportRoles\data hors file : Temp, IpFilter, réputation des expéditeurs.' }
    @{ Name = 'RoundingGB'; Group = 'Storage'; Key = 'RoundingGB'; Label = 'Arrondi des disques (Go)'; Tip = 'Les disques virtuels sont arrondis au multiple supérieur.' }
    @{ Name = 'MaxCpu'; Group = 'Compute'; Key = 'MaxCpuPercent'; Label = 'CPU maximal (%)'; Tip = 'Utilisation visée au débit de dimensionnement (80 % dans le calculateur Microsoft).' }
    @{ Name = 'Hypervisor'; Group = 'Compute'; Key = 'HypervisorOverheadPercent'; Label = 'Surcoût hyperviseur (%)'; Tip = 'Appliqué quand la référence et la cible n’’ont pas le même mode (physique ou virtuel). Microsoft : environ 10 %.' }
    @{ Name = 'TargetSpec'; Group = 'Compute'; Key = 'TargetSpecIntRatePerCore'; Label = 'SPECint par cœur'; Tip = 'SPECint_rate2017 (base) ÷ cœurs du processeur de l’’hôte de virtualisation, ou du serveur physique quand sa fiche n’’est pas saisie. Rempli par la liste des processeurs ; 0 = même performance par cœur que la référence (Xeon Platinum 8573C, 8,5).' }
    @{ Name = 'VcpuRatio'; Group = 'Compute'; Key = 'VcpuRatio'; Label = 'vCPU par cœur physique'; Tip = 'Ratio de surallocation des hôtes : somme des vCPU des VM ÷ cœurs physiques (hors hyperthreading). 1 = 1:1 (recommandé par Microsoft, ou VM avec réservation processeur), 2 = 2:1 (maximum pris en charge). Un vCPU compte pour 1 ÷ max(ratio, 1 + gain de l’’hyperthreading) d’’un cœur.' }
    @{ Name = 'SmtGain'; Group = 'Compute'; Key = 'SmtGainPercent'; Label = 'Gain hyperthreading (%)'; Tip = 'Débit d’’un cœur avec ses deux threads par rapport à un seul thread. SPEC CPU2017 : 3 à 22 % sur cinq systèmes mesurés avec et sans SMT, 20 % de médiane.' }
    @{ Name = 'MemoryReserved'; Group = 'Compute'; Key = 'MemoryReservedPercent'; Label = 'Mémoire réservée (%)'; Tip = 'Part de la RAM de la VM réservée sur l’’hôte. Microsoft ne prend pas en charge la surallocation de mémoire pour Exchange : 100 %. En dessous, le rapport donne la réservation minimale (besoin au pire moment) et ce qui se passe si l’’hôte reprend de la mémoire.' }
    @{ Name = 'RamMargin'; Group = 'Compute'; Key = 'RamMarginPercent'; Label = 'Marge RAM (%)'; Tip = 'Marge au-dessus de la RAM qui respecte les seuils de back pressure.' }
    @{ Name = 'MinRam'; Group = 'Compute'; Key = 'MinRamGB'; Label = 'RAM minimale (Go)'; Tip = 'Plancher pratique de la RAM proposée.' }
    @{ Name = 'MinCores'; Group = 'Compute'; Key = 'MinCores'; Label = 'Cœurs minimum'; Tip = 'Plancher du nombre de vCPU ou de cœurs : 4 par défaut, en dessous Windows, Exchange, l’’antivirus et la supervision n’’ont pas de marge.' }
    @{ Name = 'LinkMbps'; Group = 'Network'; Key = 'LinkMbps'; Label = 'Débit de la carte (Mbit/s)'; Tip = 'Débit de chaque carte réseau du serveur.' }
    @{ Name = 'MaxLinkUse'; Group = 'Network'; Key = 'MaxUtilizationPercent'; Label = 'Utilisation maximale (%)'; Tip = 'Utilisation visée de la carte au débit de dimensionnement.' }
    @{ Name = 'ProtocolOverhead'; Group = 'Network'; Key = 'ProtocolOverheadPercent'; Label = 'Surcoût protocolaire (%)'; Tip = 'SMTP, TLS, TCP/IP au-dessus de la taille des messages.' }
    @{ Name = 'SpecRate'; Group = 'Physical'; Key = 'SpecIntRate2017'; Label = 'SPECint_rate2017'; Tip = 'Résultat SPECint_rate2017 (base) du modèle de serveur. 0 = inconnu.' }
    @{ Name = 'PhysicalCores'; Group = 'Physical'; Key = 'Cores'; Label = 'Cœurs physiques'; Tip = 'Cœurs du serveur proposé. 0 = calculés.' }
    @{ Name = 'DiskIops'; Group = 'Physical'; Key = 'DiskIops'; Label = 'IOPS par disque de file'; Tip = '0 = IOPS aléatoires du catalogue pour le modèle sélectionné. Une valeur positive remplace le catalogue par les IOPS mesurées d’’un disque, mécanique, SSD ou NVMe. Si le constructeur ne publie pas de valeur, saisir une mesure ; aucune valeur historique n’’est supposée.' }
    @{ Name = 'SystemDiskIops'; Group = 'Physical'; Key = 'SystemDiskIops'; Label = 'IOPS par disque système'; Tip = '0 = IOPS aléatoires du catalogue pour le disque système. Une valeur positive remplace le catalogue par une mesure par disque, y compris lorsque la file est sur le système. Une valeur non publiée reste inconnue sans mesure.' }
    @{ Name = 'IoSizeKB'; Group = 'Physical'; Key = 'IoSizeKB'; Label = 'Taille moyenne des E/S (Ko)'; Tip = 'Taille moyenne d’’une E/S physique de transport, et non d’’un message. 0 = déduite des octets et des opérations mesurés du profil de transport ; une valeur positive impose la taille moyenne mesurée sur le stockage du client. Disponible aussi quand la file est sur le volume système.' }
    @{ Name = 'CpuAdjust'; Group = 'Adjustment'; Key = 'CpuPercent'; Label = 'Ajustement processeur (%)'; Tip = 'Adapte le coût processeur du profil au contexte du client quand il n’’a pas pu être mesuré sur place : processeurs plus lents (au-dessus de 100) ou plus rapides, agents ou antivirus en plus. 100 = profil tel que mesuré.' }
    @{ Name = 'IoAdjust'; Group = 'Adjustment'; Key = 'IoPercent'; Label = 'Ajustement E/S (%)'; Tip = 'Adapte les IOPS et le débit d’’écriture du profil au stockage du client (antivirus sur le dossier de la file, cache du contrôleur). 100 = profil tel que mesuré.' }
    @{ Name = 'MemoryAtRest'; Group = 'Adjustment'; Key = 'MemoryAtRestGB'; Label = 'Mémoire au repos (Go)'; Tip = 'Mémoire utilisée sans charge par un serveur du client : mémoire physique − compteur Memory\Available MBytes. 0 = valeur du profil : 3,5 Go sur l’’Edge de référence, 12,2 Go sur la Mailbox de référence (mémoire des bases du labo retirée).' }
)
# Combo boxes placed in a field grid (not text fields: read and written apart).
$script:TsGuiComboFields = @(
    @{ Name = 'PeakRateUnit'; Label = 'Unité du débit de pointe'; Tip = 'Messages par heure ou par seconde.' }
    @{ Name = 'TargetProcessor'; Label = 'Processeur de l’’hôte ou du serveur'; Editable = $true; Tip = 'Processeur des hôtes de virtualisation (ou du serveur physique) : la liste donne la médiane des résultats SPEC CPU2017 integer rate publiés, par cœur (data\Processors.csv). Saisir un autre nom et sa valeur à droite au besoin.' }
    @{ Name = 'DiskType'; Label = 'Disques de la file d’’attente'; Tip = 'Modèle ou classe du catalogue pour le volume dédié à mail.que : SSD, NVMe ou disques mécaniques en solution de repli. Les valeurs proviennent des fiches constructeur, pas de l’’ancienne table Microsoft.' }
    @{ Name = 'DiskSize'; Label = 'Taille par disque (Go)'; Editable = $true; Tip = '0 = automatique : choisir une capacité du catalogue selon le besoin du volume de la file. Sinon, saisir la capacité brute constructeur d’’un disque, même hors catalogue.' }
    @{ Name = 'SystemDiskType'; Label = 'Disques système'; Tip = 'Modèle ou classe du catalogue système : carte de démarrage M.2 en RAID-1 (BOSS-N1, NS204i) ou disques en façade. Ces disques portent aussi mail.que lorsque la file est sur le système.' }
    @{ Name = 'SystemDiskSize'; Label = 'Taille par disque (Go)'; Editable = $true; Tip = '0 = automatique : choisir une capacité du catalogue selon le besoin du volume système, file comprise si elle y réside. Sinon, saisir la capacité brute constructeur, même hors catalogue.' }
)
$script:TsGuiSizeCombos = @(
    @{ Type = 'DiskType'; Size = 'DiskSize'; TypeKey = 'DiskType'; SizeKey = 'DiskSizeGB'; Role = 'Transport'; Info = 'DiskCatalogInfo'; Label = 'Taille des disques de la file' }
    @{ Type = 'SystemDiskType'; Size = 'SystemDiskSize'; TypeKey = 'SystemDiskType'; SizeKey = 'SystemDiskSizeGB'; Role = 'System'; Info = 'SystemDiskCatalogInfo'; Label = 'Taille des disques système' }
)
$script:TsGuiPlaceholders = [ordered]@{
    'F:Scenario'   = @('ScenarioName', 'Customer', 'Author')
    'F:Load'       = @('Growth', 'Burst', 'TransportRules', 'TlsPercent', 'PerSession')
    'F:Day'        = @('WorkingHours', 'OffHours', 'PeakHours', 'PeakHour', 'PeakRate', 'PeakRateUnit')
    'F:Resilience' = @('Expiration', 'Outage', 'Residence', 'ReclaimDays', 'DrainTarget')
    'F:Mailbox'    = @('SafetyNet', 'ReplayLag')
    'F:Journal'    = @('JournalPercent', 'JournalRecipients', 'JournalOverhead')
    'F:Storage'    = @('MaxFill', 'IoOverhead', 'RoundingGB')
    'F:System'     = @('OsGB', 'BinariesGB', 'DiagnosticGB', 'TransportLogsGB', 'OtherDataGB')
    'F:Host'       = @('TargetProcessor', 'TargetSpec')
    'F:Compute'    = @('VcpuRatio', 'SmtGain', 'MinCores', 'MaxCpu', 'Hypervisor', 'MemoryReserved', 'RamMargin', 'MinRam')
    'F:Network'    = @('LinkMbps', 'MaxLinkUse', 'ProtocolOverhead')
    'F:Physical'   = @('SpecRate', 'PhysicalCores', 'IoSizeKB')
    'F:QueueDisks' = @('DiskType', 'DiskSize', 'DiskIops')
    'F:SystemDisks' = @('SystemDiskType', 'SystemDiskSize', 'SystemDiskIops')
    'F:Adjustment' = @('CpuAdjust', 'IoAdjust', 'MemoryAtRest')
}

function ConvertTo-TsXmlText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return [Security.SecurityElement]::Escape($Text)
}

function Get-TsGuiFieldXaml {
    <# A grid of labelled text boxes, three per row (Widths: star widths of the columns). #>
    param([Parameter(Mandatory = $true)][string[]]$Names, [int]$Columns = 3, [string[]]$Widths)

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('<Grid><Grid.ColumnDefinitions>')
    for ($i = 0; $i -lt $Columns; $i++) {
        if ($i -gt 0) { [void]$builder.Append('<ColumnDefinition Width="12"/>') }
        $width = '*'
        if ($Widths -and $i -lt $Widths.Count) { $width = $Widths[$i] }
        [void]$builder.AppendFormat('<ColumnDefinition Width="{0}"/>', $width)
    }
    [void]$builder.Append('</Grid.ColumnDefinitions><Grid.RowDefinitions>')
    $rows = [Math]::Ceiling($Names.Count / $Columns)
    for ($i = 0; $i -lt $rows; $i++) { [void]$builder.Append('<RowDefinition Height="Auto"/>') }
    [void]$builder.Append('</Grid.RowDefinitions>')
    for ($i = 0; $i -lt $Names.Count; $i++) {
        $field = $script:TsGuiFields | Where-Object { $_.Name -eq $Names[$i] } | Select-Object -First 1
        $control = 'TextBox'
        if (-not $field) { $field = $script:TsGuiComboFields | Where-Object { $_.Name -eq $Names[$i] } | Select-Object -First 1; $control = 'ComboBox' }
        $tip = ''
        if ($field.ContainsKey('Tip')) { $tip = ' ToolTip="{0}"' -f (ConvertTo-TsXmlText $field.Tip) }
        $extra = ''
        if ($control -eq 'ComboBox' -and $field.ContainsKey('Editable')) { $extra = ' IsEditable="True"' }
        [void]$builder.AppendFormat('<StackPanel Grid.Row="{0}" Grid.Column="{1}"><TextBlock Text="{2}" Style="{{StaticResource TsLabel}}"{3}/><{5} x:Name="{4}"{3}{6}/></StackPanel>',
            [Math]::Floor($i / $Columns), 2 * ($i % $Columns), (ConvertTo-TsXmlText $field.Label), $tip, $field.Name, $control, $extra)
    }
    [void]$builder.Append('</Grid>')
    return $builder.ToString()
}

function Get-TsGuiXaml {
    <# The window. Colours come from the Fluent theme resources (or the classic fallback of Set-TsGuiTheme). #>
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1440" Height="940" MinWidth="1100" MinHeight="640" WindowStartupLocation="CenterScreen" Language="fr-FR"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="TsCard" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource CardBackgroundFillColorDefaultBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource CardStrokeColorDefaultBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="18,14,18,16"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="TsCardTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
      <Setter Property="Foreground" Value="{DynamicResource TextFillColorPrimaryBrush}"/>
    </Style>
    <Style x:Key="TsLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{DynamicResource TextFillColorSecondaryBrush}"/>
      <Setter Property="Margin" Value="0,8,0,4"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="TsHint" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Foreground" Value="{DynamicResource TextFillColorSecondaryBrush}"/>
    </Style>
    <Style x:Key="TsIcon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
    </Style>
    <Style x:Key="TsRole" TargetType="ListBoxItem">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Card" Margin="0,0,8,0" Padding="12,10,10,10" CornerRadius="6" BorderThickness="2"
                    Background="{DynamicResource ControlFillColorDefaultBrush}" BorderBrush="{DynamicResource ControlStrokeColorDefaultBrush}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Card" Property="Background" Value="{DynamicResource ControlFillColorSecondaryBrush}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Card" Property="BorderBrush" Value="{DynamicResource AccentFillColorDefaultBrush}"/>
                <Setter TargetName="Card" Property="Background" Value="{DynamicResource TsAccentSoft}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid x:Name="Root" Background="{DynamicResource ApplicationBackgroundBrush}">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid x:Name="Header" Margin="24,18,24,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Border Width="46" Height="46" CornerRadius="10" Background="{DynamicResource TsBrand}" VerticalAlignment="Center">
        <TextBlock Style="{StaticResource TsIcon}" Text="&#xE8EF;" FontSize="22" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center">
        <TextBlock Text="EXCHANGE · DIMENSIONNEMENT DU TRANSPORT" FontSize="11" FontWeight="SemiBold" Foreground="{DynamicResource TsBrandText}"/>
        <TextBlock Text="Transport Sizer" FontSize="24" FontWeight="SemiBold" Foreground="{DynamicResource TextFillColorPrimaryBrush}"/>
        <TextBlock FontSize="13" Foreground="{DynamicResource TextFillColorSecondaryBrush}" TextTrimming="CharacterEllipsis"
                   Text="Saisir le trafic et la topologie : le serveur se recalcule à chaque modification, le rapport HTML explique chaque chiffre."/>
      </StackPanel>
      <TextBlock x:Name="Version" Grid.Column="2" FontSize="12" Foreground="{DynamicResource TextFillColorSecondaryBrush}" VerticalAlignment="Top"/>
    </Grid>

    <Grid Grid.Row="1" Margin="24,0,24,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="680"/>
        <ColumnDefinition Width="16"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <ScrollViewer x:Name="FormScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="0,0,6,0">
        <StackPanel>
          <Border Style="{StaticResource TsCard}">
            <StackPanel>
              <TextBlock Text="Scénario" Style="{StaticResource TsCardTitle}"/>
              {{F:Scenario}}
            </StackPanel>
          </Border>

          <Border Style="{StaticResource TsCard}">
            <StackPanel>
              <TextBlock Text="Rôle et déploiement" Style="{StaticResource TsCardTitle}" Margin="0,0,0,10"/>
              <ListBox x:Name="Role" ItemContainerStyle="{StaticResource TsRole}" BorderThickness="0" Background="Transparent" Padding="0"
                       ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.VerticalScrollBarVisibility="Disabled">
                <ListBox.ItemsPanel>
                  <ItemsPanelTemplate><UniformGrid Columns="2"/></ItemsPanelTemplate>
                </ListBox.ItemsPanel>
              </ListBox>
              <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                <TextBlock Text="Déploiement" Style="{StaticResource TsLabel}" Margin="0,0,16,0" VerticalAlignment="Center"/>
                <RadioButton x:Name="Virtual" Content="Virtuel" GroupName="Deployment" Margin="0,0,20,0" VerticalAlignment="Center"/>
                <RadioButton x:Name="Physical" Content="Physique" GroupName="Deployment" VerticalAlignment="Center"/>
              </StackPanel>
              <TextBlock x:Name="RoleHint" Style="{StaticResource TsHint}" Margin="0,10,0,0"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource TsCard}">
            <StackPanel>
              <TextBlock Text="Topologie" Style="{StaticResource TsCardTitle}"/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="12"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="12"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="Sites" Style="{StaticResource TsLabel}"/>
                  <ComboBox x:Name="Sites" ToolTip="Sites qui hébergent des serveurs de ce rôle (au plus deux)."/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <TextBlock Text="Serveurs par site" Style="{StaticResource TsLabel}"/>
                  <TextBox x:Name="ServersPerSite" ToolTip="Serveurs de ce rôle dans chaque site (même nombre dans chaque site)."/>
                </StackPanel>
                <StackPanel Grid.Column="4">
                  <TextBlock Text="Dimensionner pour" Style="{StaticResource TsLabel}"/>
                  <ComboBox x:Name="Failure" ToolTip="Panne que les serveurs restants doivent absorber avec tout le trafic."/>
                </StackPanel>
              </Grid>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource TsCard}">
            <StackPanel>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="Flux de messages (organisation, par jour)" Style="{StaticResource TsCardTitle}" VerticalAlignment="Center"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal">
                  <Button x:Name="ImportLogReport" Padding="10,4" Margin="0,0,8,0" ToolTip="Remplacer les flux par le trafic mesuré par Exchange Log Report (rapport détaillé, fichier &lt;préfixe&gt;-Messages.csv) : messages par jour, tailles, heure de pointe, messages par session, TLS.">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource TsIcon}" Text="&#xE8B5;" Margin="0,2,6,0"/><TextBlock Text="Importer…"/></StackPanel>
                  </Button>
                  <Button x:Name="AddFlow" Padding="10,4" Margin="0,0,8,0" ToolTip="Ajouter un flux">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource TsIcon}" Text="&#xE710;" Margin="0,2,6,0"/><TextBlock Text="Ajouter"/></StackPanel>
                  </Button>
                  <Button x:Name="RemoveFlow" Padding="10,4" ToolTip="Supprimer le flux sélectionné">
                    <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource TsIcon}" Text="&#xE74D;" Margin="0,2,6,0"/><TextBlock Text="Supprimer"/></StackPanel>
                  </Button>
                </StackPanel>
              </Grid>
              <DataGrid x:Name="Flows" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False" CanUserReorderColumns="False" CanUserSortColumns="False"
                        HeadersVisibility="Column" SelectionMode="Single" SelectionUnit="FullRow" GridLinesVisibility="Horizontal" Height="196" Margin="0,10,0,0" FontSize="13">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Flux" Binding="{Binding Name, UpdateSourceTrigger=PropertyChanged}" Width="2*"/>
                  <DataGridComboBoxColumn Header="Sens" SelectedItemBinding="{Binding Direction, UpdateSourceTrigger=PropertyChanged}" Width="0.95*"/>
                  <DataGridTextColumn Header="Msg / jour" Binding="{Binding MessagesPerDay, UpdateSourceTrigger=PropertyChanged}" Width="1.05*"/>
                  <DataGridTextColumn Header="Taille Ko" Binding="{Binding AverageSizeKB, UpdateSourceTrigger=PropertyChanged}" Width="0.85*"/>
                  <DataGridTextColumn Header="Transm." Binding="{Binding FanOut, UpdateSourceTrigger=PropertyChanged}" Width="0.8*"/>
                  <DataGridTemplateColumn Header="Panne" Width="0.7*">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate><CheckBox IsChecked="{Binding Held, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" VerticalAlignment="Center"/></DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                </DataGrid.Columns>
              </DataGrid>
              <TextBlock Style="{StaticResource TsHint}" Margin="0,8,0,0"
                         Text="Msg / jour : messages par jour pour toute l’organisation. Transm. : envois SMTP par message (bifurcation par domaine ou serveur de destination). Panne : flux retenu dans la file quand le saut suivant est injoignable."/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource TsCard}">
            <StackPanel>
              <TextBlock Text="Charge" Style="{StaticResource TsCardTitle}"/>
              {{F:Load}}
              <TextBlock Text="Journée de trafic et pointe" FontWeight="SemiBold" Margin="0,14,0,0"/>
              {{F:Day}}
              <TextBlock x:Name="DaySummary" Style="{StaticResource TsHint}" Margin="0,8,0,0" TextWrapping="Wrap"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource TsCard}">
            <StackPanel>
              <TextBlock Text="Résilience" Style="{StaticResource TsCardTitle}"/>
              {{F:Resilience}}
              <Border x:Name="MailboxPanel" Margin="0,12,0,0" Padding="12,4,12,12" CornerRadius="6" BorderThickness="1"
                      Background="{DynamicResource TsPanelBackground}" BorderBrush="{DynamicResource CardStrokeColorDefaultBrush}">
                <StackPanel>
                  <TextBlock Text="Rôle Mailbox : Safety Net et redondance shadow" Style="{StaticResource TsLabel}" FontWeight="SemiBold" Margin="0,8,0,0"/>
                  {{F:Mailbox}}
                  <CheckBox x:Name="Shadow" Content="Redondance shadow (ShadowRedundancyEnabled)" Margin="0,12,0,0"
                            ToolTip="Set-TransportConfig -ShadowRedundancyEnabled. Effective avec au moins deux serveurs restants dans la frontière (site AD sans DAG, DAG sinon)."/>
                  <CheckBox x:Name="Dag" Content="Serveurs membres d’un DAG" Margin="0,8,0,0"
                            ToolTip="Sans DAG, la copie shadow est faite sur un autre serveur Mailbox du même site AD. Dans un DAG, elle peut être faite dans un autre site."/>
                </StackPanel>
              </Border>
              <TextBlock x:Name="EdgeNotice" Style="{StaticResource TsHint}" Margin="0,10,0,0"
                         Text="Edge Transport : Safety Net et la redondance shadow ne concernent que le rôle Mailbox ; ils ne sont pas comptés."/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource TsCard}">
            <StackPanel>
              <TextBlock Text="Journalisation" Style="{StaticResource TsCardTitle}"/>
              <StackPanel x:Name="JournalPanel">
                <CheckBox x:Name="JournalEnabled" Content="Journalisation active (règles de journal ou journalisation standard)"
                          ToolTip="L’agent de journalisation des serveurs Mailbox écrit un rapport par message journalisé : le message d’origine joint, inchangé, et son enveloppe. Les rapports passent par la file, Safety Net et la redondance shadow comme les autres messages."/>
                <Grid Margin="0,10,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="12"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel>
                    <TextBlock Text="Portée" Style="{StaticResource TsLabel}"/>
                    <ComboBox x:Name="JournalScope" ToolTip="Messages internes (source et destination dans l’organisation), externes (expéditeur ou destinataire hors de l’organisation) ou tous."/>
                  </StackPanel>
                  <StackPanel Grid.Column="2">
                    <TextBlock Text="Destination des rapports" Style="{StaticResource TsLabel}"/>
                    <ComboBox x:Name="JournalDestination" ToolTip="Archive externe : les rapports sortent de l’organisation (flux sortant, par les Edge le cas échéant). Boîte interne : ils sont remis à un serveur de boîtes."/>
                  </StackPanel>
                </Grid>
                {{F:Journal}}
                <CheckBox x:Name="JournalHeld" Content="Rapports retenus quand la destination est injoignable" Margin="0,12,0,0"
                          ToolTip="Les rapports non remis restent en file et sont réessayés jusqu’à l’expiration (MessageExpirationTimeout). Décocher seulement avec une boîte de journalisation de secours qui reçoit les rapports non remis."/>
              </StackPanel>
              <TextBlock x:Name="JournalNotice" Style="{StaticResource TsHint}" Margin="0,10,0,0"
                         Text="Edge Transport : la journalisation est faite par les serveurs Mailbox. Si l’archive externe est jointe par les Edge, saisir ses rapports comme un flux sortant."/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource TsCard}">
            <StackPanel>
              <TextBlock Text="Stockage" Style="{StaticResource TsCardTitle}"/>
              <TextBlock Text="Emplacement de la file d’attente" Style="{StaticResource TsLabel}"/>
              <ComboBox x:Name="QueueVolume" ToolTip="Volume dédié à mail.que et à ses journaux, ou volume système."/>
              {{F:Storage}}
              <Expander Header="Contenu du volume système" Margin="0,12,0,0">
                <StackPanel Margin="0,0,0,2">
                  {{F:System}}
                </StackPanel>
              </Expander>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource TsCard}">
            <StackPanel>
              <TextBlock Text="Calcul et réseau" Style="{StaticResource TsCardTitle}"/>
              {{F:Host}}
              {{F:Compute}}
              <CheckBox x:Name="EvenVcpu" Content="vCPU en nombre pair (VMware, Hyper-V)" Margin="0,4,0,12"
                        ToolTip="Arrondit les vCPU au nombre pair supérieur : sockets × cœurs, vNUMA et paires de threads des cœurs physiques."/>
              {{F:Network}}
            </StackPanel>
          </Border>

          <Border x:Name="PhysicalCard" Style="{StaticResource TsCard}">
            <StackPanel>
              <TextBlock Text="Serveur physique" Style="{StaticResource TsCardTitle}"/>
              {{F:Physical}}
              {{F:QueueDisks}}
              <TextBlock x:Name="DiskCatalogInfo" Style="{StaticResource TsHint}" Margin="0,6,0,0"/>
              {{F:SystemDisks}}
              <TextBlock x:Name="SystemDiskCatalogInfo" Style="{StaticResource TsHint}" Margin="0,6,0,0"/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="12"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="RAID de la file d’attente" Style="{StaticResource TsLabel}"/>
                  <ComboBox x:Name="QueueRaid"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <TextBlock Text="RAID du système" Style="{StaticResource TsLabel}"/>
                  <ComboBox x:Name="SystemRaid"/>
                </StackPanel>
              </Grid>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource TsCard}">
            <StackPanel>
              <TextBlock Text="Profil de calibration" Style="{StaticResource TsCardTitle}"/>
              <TextBlock Style="{StaticResource TsHint}" Margin="0,4,0,10"
                         Text="Processeur, mémoire et IOPS viennent d’un profil mesuré. Par défaut, le profil de référence du rôle (mesures du labo) donne un dimensionnement générique. Si un serveur Exchange du client peut être mesuré (calibration\Measure-TransportLoad.ps1), importer son profil ; sinon, adapter le profil avec les ajustements."/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="CalibrationIcon" Style="{StaticResource TsIcon}" FontSize="16" Margin="0,2,10,0" VerticalAlignment="Top"/>
                <TextBlock x:Name="CalibrationStatus" Grid.Column="1" TextWrapping="Wrap" FontSize="13" VerticalAlignment="Center" Foreground="{DynamicResource TextFillColorPrimaryBrush}"/>
                <Button x:Name="ImportCalibration" Grid.Column="2" Content="Importer un profil…" Padding="12,5" Margin="12,0,8,0" VerticalAlignment="Center"/>
                <Button x:Name="RemoveCalibration" Grid.Column="3" Content="Profil de référence" Padding="12,5" VerticalAlignment="Center" ToolTip="Revenir au profil de référence du rôle (mesures du labo)."/>
              </Grid>
              <TextBlock Text="Ajustements du profil" FontWeight="SemiBold" Margin="0,14,0,0"/>
              {{F:Adjustment}}
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <Grid Grid.Column="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Border Style="{StaticResource TsCard}">
          <StackPanel>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="Serveur dimensionné" Style="{StaticResource TsCardTitle}"/>
              <Border x:Name="StatusPill" Grid.Column="1" CornerRadius="10" Padding="10,2" Background="{DynamicResource TsInfoBackground}">
                <TextBlock x:Name="Status" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource TextFillColorPrimaryBrush}"/>
              </Border>
            </Grid>
            <TextBlock x:Name="ResultSubtitle" Style="{StaticResource TsHint}" Margin="0,2,0,10"/>
            <UniformGrid x:Name="Tiles" Columns="4"/>
          </StackPanel>
        </Border>
        <Border Grid.Row="1" Style="{StaticResource TsCard}">
          <StackPanel>
            <TextBlock Text="Configuration cible, par serveur" Style="{StaticResource TsCardTitle}" Margin="0,0,0,8"/>
            <ItemsControl x:Name="Config">
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <Grid Margin="0,3,0,3">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="170"/>
                      <ColumnDefinition Width="170"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="{Binding Component}" FontSize="13" Foreground="{DynamicResource TextFillColorSecondaryBrush}"/>
                    <TextBlock Grid.Column="1" Text="{Binding Value}" FontSize="13" FontWeight="SemiBold" Foreground="{Binding Brush}" TextWrapping="Wrap"/>
                    <TextBlock Grid.Column="2" Text="{Binding Detail}" FontSize="12" Foreground="{DynamicResource TextFillColorSecondaryBrush}" TextWrapping="Wrap"/>
                  </Grid>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </StackPanel>
        </Border>
        <Border Grid.Row="2" Style="{StaticResource TsCard}">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <TextBlock Text="Contrôles" Style="{StaticResource TsCardTitle}" Margin="0,0,0,8"/>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <ItemsControl x:Name="Checks">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Grid Margin="0,3,0,5">
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="24"/>
                        <ColumnDefinition Width="*"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Text="{Binding Glyph}" Foreground="{Binding Brush}" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13" Margin="0,3,0,0" VerticalAlignment="Top"/>
                      <TextBlock Grid.Column="1" Text="{Binding Text}" TextWrapping="Wrap" FontSize="13" Foreground="{DynamicResource TextFillColorPrimaryBrush}"/>
                    </Grid>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </ScrollViewer>
          </Grid>
        </Border>
      </Grid>
    </Grid>

    <Border x:Name="Actions" Grid.Row="2" Padding="24,12,24,14" BorderThickness="0,1,0,0"
            Background="{DynamicResource LayerFillColorDefaultBrush}" BorderBrush="{DynamicResource DividerStrokeColorDefaultBrush}">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal">
          <Button x:Name="New" Content="Nouveau" Padding="14,6" Margin="0,0,8,0" ToolTip="Valeurs par défaut du rôle choisi (la calibration est gardée)."/>
          <Button x:Name="Open" Content="Ouvrir…" Padding="14,6" Margin="0,0,8,0"/>
          <Button x:Name="Save" Content="Enregistrer…" Padding="14,6"/>
        </StackPanel>
        <TextBlock x:Name="Footer" Grid.Column="1" Margin="16,0" FontSize="12" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"
                   Foreground="{DynamicResource TextFillColorSecondaryBrush}"/>
        <StackPanel Grid.Column="2" Orientation="Horizontal">
          <Button x:Name="OpenSynthesis" Content="Ouvrir la synthèse" Padding="14,6" Margin="0,0,8,0" IsEnabled="False"
                  ToolTip="Synthèse visuelle pour le client : architecture, serveur cible, capacité, réseau, incident."/>
          <Button x:Name="OpenReport" Content="Rapport technique" Padding="14,6" Margin="0,0,8,0" IsEnabled="False"
                  ToolTip="Rapport détaillé : chaque valeur avec sa formule, son calcul et son origine."/>
          <Button x:Name="OpenFolder" Content="Ouvrir le dossier" Padding="14,6" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="Report" Padding="16,6" Margin="0,0,8,0" IsDefault="False">
            <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource TsIcon}" Text="&#xE9F9;" Margin="0,2,8,0"/><TextBlock Text="Générer le rapport"/></StackPanel>
          </Button>
          <Button x:Name="Close" Content="Fermer" Padding="14,6" IsCancel="True"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@
    foreach ($key in $script:TsGuiPlaceholders.Keys) {
        $widths = $null; $columns = 3
        if ($key -eq 'F:Scenario') { $widths = @('2*', '*', '*') }
        if ($key -eq 'F:Host') { $widths = @('2*', '*'); $columns = 2 }
        if ($key -in 'F:QueueDisks', 'F:SystemDisks') { $widths = @('2*', '*', '*') }
        $xaml = $xaml.Replace("{{$key}}", (Get-TsGuiFieldXaml -Names $script:TsGuiPlaceholders[$key] -Widths $widths -Columns $columns))
    }
    return $xaml
}

function New-TsGuiBrush {
    param([Parameter(Mandatory = $true)][string]$Color)
    $brush = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($Color))
    $brush.Freeze()
    return $brush
}

function Test-TsGuiDarkMode {
    <# Windows shows the applications in dark mode (AppsUseLightTheme = 0); light when the setting is missing. #>
    $personalize = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
    return [string](Get-TsField $personalize 'AppsUseLightTheme' '1') -eq '0'
}

function Initialize-TsGuiTheme {
    <#
        Loads WPF and applies the theme to the application: Fluent (.NET 9+), light or dark as Windows
        (System), or Light / Dark for the documentation images. Returns Fluent and Dark.
    #>
    param([ValidateSet('System', 'Light', 'Dark')][string]$Theme = 'System')

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    $dark = $Theme -eq 'Dark'
    if ($Theme -eq 'System') { $dark = Test-TsGuiDarkMode }
    # One application per process: created once, never shut down by a closed window.
    $app = [Windows.Application]::Current
    if (-not $app) {
        $app = [Windows.Application]::new()
        $app.ShutdownMode = [Windows.ShutdownMode]::OnExplicitShutdown
    }
    $fluent = $null -ne [Windows.Application].GetProperty('ThemeMode')
    if ($fluent) {
        # Light or Dark, never System: without the setting (Windows Server) WPF would pick dark.
        $app.ThemeMode = [Windows.ThemeMode]::new($(if ($dark) { 'Dark' } else { 'Light' }))
    }
    [pscustomobject]@{ Fluent = $fluent; Dark = $dark; Application = $app }
}

function Set-TsGuiTheme {
    <#
        Colours of the window: the accent of the report on the Fluent accent resources, the status colours,
        and with the classic theme (.NET Framework, .NET 8) the Fluent resources the window uses.
    #>
    param([Parameter(Mandatory = $true)][Windows.Window]$Window, [Parameter(Mandatory = $true)][pscustomobject]$Theme)

    $dark = $Theme.Dark
    $r = $Window.Resources
    $set = { param([string[]]$Keys, [string]$LightColor, [string]$DarkColor) $b = New-TsGuiBrush $(if ($dark) { $DarkColor } else { $LightColor }); foreach ($k in $Keys) { $r[$k] = $b } }
    if (-not $Theme.Fluent) {
        & $set 'ApplicationBackgroundBrush' '#F7F4EF' '#202020'
        & $set 'CardBackgroundFillColorDefaultBrush' '#FFFFFF' '#2B2B2B'
        & $set 'CardStrokeColorDefaultBrush', 'ControlStrokeColorDefaultBrush' '#DEDEDE' '#3D3D3D'
        & $set 'ControlFillColorDefaultBrush' '#FFFFFF' '#2D2D2D'
        & $set 'ControlFillColorSecondaryBrush' '#F5F5F5' '#323232'
        & $set 'DividerStrokeColorDefaultBrush' '#DEDEDE' '#3D3D3D'
        & $set 'LayerFillColorDefaultBrush' '#FCFBF8' '#262626'
        & $set 'TextFillColorPrimaryBrush' '#242424' '#FFFFFF'
        & $set 'TextFillColorSecondaryBrush' '#5C5C5C' '#C5C5C5'
        & $set 'TextFillColorTertiaryBrush' '#8A8A8A' '#9A9A9A'
    }
    & $set 'AccentFillColorDefaultBrush', 'AccentButtonBackground', 'AccentButtonBorderBrush' '#B11F4B' '#FD8EA1'
    & $set 'AccentFillColorSecondaryBrush', 'AccentButtonBackgroundPointerOver' '#E6B11F4B' '#E6FD8EA1'
    & $set 'AccentFillColorTertiaryBrush', 'AccentButtonBackgroundPressed' '#CCB11F4B' '#CCFD8EA1'
    & $set 'AccentTextFillColorPrimaryBrush' '#9A1A41' '#FD8EA1'
    & $set 'TsBrand' '#B11F4B' '#B11F4B'
    & $set 'TsBrandText' '#B11F4B' '#FD8EA1'
    & $set 'TsAccentSoft' '#14B11F4B' '#33FD8EA1'
    & $set 'TsPanelBackground' '#FAF7F3' '#262626'
    & $set 'TsSuccess' '#16A34A' '#4ADE80'
    & $set 'TsCaution' '#D97706' '#FBBF24'
    & $set 'TsCritical' '#DC2626' '#F87171'
    & $set 'TsInfo' '#2563EB' '#60A5FA'
    & $set 'TsInfoBackground' '#F3F3F3' '#2E2E2E'
    & $set 'TsCautionBackground' '#FFF7E8' '#33FBBF24'
    & $set 'TsCriticalBackground' '#FDECEC' '#33F87171'
    & $set 'TsSuccessBackground' '#EAF7EE' '#334ADE80'
    & $set 'TsTileBackground' '#FCFBF8' '#262626'
}

function New-TsGuiRoleCard {
    <# Content of one role card: icon, name, what is counted. #>
    param([Parameter(Mandatory = $true)][pscustomobject]$Role)

    $panel = [Windows.Controls.StackPanel]::new()
    $head = [Windows.Controls.StackPanel]::new()
    $head.Orientation = [Windows.Controls.Orientation]::Horizontal
    $icon = [Windows.Controls.TextBlock]::new()
    $icon.Text = [string][char]$Role.Glyph
    $icon.FontFamily = [Windows.Media.FontFamily]::new($script:TsGuiIconFont)
    $icon.FontSize = 18
    $icon.Margin = [Windows.Thickness]::new(0, 0, 10, 0)
    $icon.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $icon.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TsBrandText')
    $name = [Windows.Controls.TextBlock]::new()
    $name.Text = $Role.Title
    $name.FontSize = 14
    $name.FontWeight = [Windows.FontWeights]::SemiBold
    $name.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $name.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextFillColorPrimaryBrush')
    [void]$head.Children.Add($icon)
    [void]$head.Children.Add($name)
    $detail = [Windows.Controls.TextBlock]::new()
    $detail.Text = $Role.Detail
    $detail.FontSize = 12
    $detail.Margin = [Windows.Thickness]::new(0, 6, 0, 0)
    $detail.TextWrapping = [Windows.TextWrapping]::Wrap
    $detail.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextFillColorSecondaryBrush')
    [void]$panel.Children.Add($head)
    [void]$panel.Children.Add($detail)
    $item = [Windows.Controls.ListBoxItem]::new()
    $item.Content = $panel
    return $item
}

function New-TsGuiTile {
    <# One result tile: label, value with its unit, note. Returns the border and its text blocks. #>
    param([Parameter(Mandatory = $true)][string]$Label)

    $border = [Windows.Controls.Border]::new()
    $border.CornerRadius = [Windows.CornerRadius]::new(8)
    $border.BorderThickness = [Windows.Thickness]::new(1)
    $border.Padding = [Windows.Thickness]::new(12, 10, 12, 10)
    $border.Margin = [Windows.Thickness]::new(0, 0, 8, 8)
    $border.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'TsTileBackground')
    $border.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'CardStrokeColorDefaultBrush')
    $panel = [Windows.Controls.StackPanel]::new()
    $title = [Windows.Controls.TextBlock]::new()
    $title.Text = $Label
    $title.FontSize = 12
    $title.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    $title.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextFillColorSecondaryBrush')
    $value = [Windows.Controls.TextBlock]::new()
    $value.FontSize = 24
    $value.FontWeight = [Windows.FontWeights]::SemiBold
    $value.Margin = [Windows.Thickness]::new(0, 4, 0, 2)
    $value.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    $value.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextFillColorPrimaryBrush')
    $note = [Windows.Controls.TextBlock]::new()
    $note.FontSize = 11
    $note.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    $note.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextFillColorSecondaryBrush')
    foreach ($part in $title, $value, $note) { [void]$panel.Children.Add($part) }
    $border.Child = $panel
    [pscustomobject]@{ Border = $border; Value = $value; Note = $note }
}

function Format-TsGuiNumber {
    <# A number for a text box: comma decimals, no thousands separator. #>
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return ([double]$Value).ToString('0.###', $script:TsCulture)
}

function Get-TsGuiKey {
    <# The code of a French label shown in a combo box (Perte d'un serveur -> OneServer). #>
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Map, [AllowNull()][object]$Label)
    foreach ($key in $Map.Keys) { if ($Map[$key] -eq [string]$Label) { return $key } }
    return $null
}

function Set-TsGuiSizes {
    <# A model supplies its own capacities; an imported capacity may be outside its catalogue. #>
    param([Parameter(Mandatory = $true)][string]$Size, [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][ValidateSet('Transport', 'System')][string]$Role,
        [Parameter(Mandatory = $true)][string]$Info, [double]$SizeGB = 0)

    $c = $script:Gui.Controls
    $disk = Get-TsDiskCatalog -Role $Role -Name $Type | Select-Object -First 1
    $box = $c[$Size]
    $box.Items.Clear()
    [void]$box.Items.Add('0')
    $sizes = @((Get-TsField $disk 'SizesGB' @()) | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    foreach ($capacity in $sizes) { [void]$box.Items.Add(([double]$capacity).ToString('R', $script:TsCulture)) }
    $text = $SizeGB.ToString('R', $script:TsCulture)
    if (-not $box.Items.Contains($text)) { [void]$box.Items.Add($text) }
    $box.SelectedItem = $text
    $box.Text = $text
    $box.ClearValue([Windows.Controls.Control]::BorderBrushProperty)

    $iops = [double](Get-TsField $disk 'RandomIops' 0)
    $detail = $(if ($iops -gt 0) { 'IOPS catalogue : {0} par disque.' -f (Format-TsGuiNumber $iops) } else { 'IOPS catalogue non publiées : saisir une mesure par disque.' })
    $basis = [string](Get-TsField $disk 'IopsBasis' '')
    if ($basis) { $detail += " $basis" }
    if ($sizes.Count -eq 0) { $detail += ' Capacités catalogue non publiées : saisir la taille du disque.' }
    $c[$Info].Text = $detail
    $c[$Info].ToolTip = (@(
            $detail
            $(if (Get-TsField $disk 'Source' '') { 'Source : ' + $disk.Source })
            $(if (Get-TsField $disk 'Reference' '') { 'Référence : ' + $disk.Reference })
            $(if (Get-TsField $disk 'Note' '') { $disk.Note })
        ) -join "`n")
}

function New-TsSizerForm {
    <#
    .SYNOPSIS
        Builds the window (without showing it). Used by Show-TsSizerGui, the tests and the documentation.
    .PARAMETER Scenario
        Scenario shown first. Default: the Edge scenario of Get-TsDefaultScenario.
    .PARAMETER OutputPath
        Folder of the reports. Default: reports under the tool folder.
    .PARAMETER Theme
        System (like Windows), Light or Dark.
    #>
    [CmdletBinding()]
    param([object]$Scenario, [string]$OutputPath, [ValidateSet('System', 'Light', 'Dark')][string]$Theme = 'System')

    if (-not $Scenario) { $Scenario = Get-TsDefaultScenario -Role Edge }
    if (-not $OutputPath) { $OutputPath = Join-Path $script:ToolRoot 'reports' }
    $look = Initialize-TsGuiTheme -Theme $Theme
    $window = [Windows.Markup.XamlReader]::Parse((Get-TsGuiXaml))
    $window.Title = "Transport Sizer $($script:ToolVersion)"
    Set-TsGuiTheme -Window $window -Theme $look
    $controls = @{}
    $names = @('Root', 'Version', 'FormScroll', 'Role', 'Virtual', 'Physical', 'RoleHint', 'Sites', 'Failure', 'Flows', 'ImportLogReport', 'AddFlow', 'RemoveFlow', 'MailboxPanel', 'Shadow', 'Dag', 'EdgeNotice', 'EvenVcpu',
        'PeakRateUnit', 'DaySummary', 'TargetProcessor',
        'JournalPanel', 'JournalEnabled', 'JournalScope', 'JournalDestination', 'JournalHeld', 'JournalNotice',
        'QueueVolume', 'PhysicalCard', 'DiskType', 'DiskSize', 'DiskCatalogInfo', 'SystemDiskType', 'SystemDiskSize', 'SystemDiskCatalogInfo', 'QueueRaid', 'SystemRaid', 'CalibrationIcon', 'CalibrationStatus', 'ImportCalibration', 'RemoveCalibration',
        'StatusPill', 'Status', 'ResultSubtitle', 'Tiles', 'Config', 'Checks', 'Actions', 'New', 'Open', 'Save', 'Footer', 'OpenReport', 'OpenSynthesis', 'OpenFolder', 'Report', 'Close')
    foreach ($name in $names + @($script:TsGuiFields | ForEach-Object { $_.Name })) { $controls[$name] = $window.FindName($name) }
    if ($look.Fluent) { $controls.Report.SetResourceReference([Windows.FrameworkElement]::StyleProperty, 'AccentButtonStyle') }
    else {
        $controls.Report.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, 'AccentFillColorDefaultBrush')
        $controls.Report.Foreground = [Windows.Media.Brushes]::White
        foreach ($field in $script:TsGuiFields) { $controls[$field.Name].Padding = [Windows.Thickness]::new(6, 4, 6, 4) }
    }
    $controls.Version.Text = "v$($script:ToolVersion)  " + [char]0x00B7 + '  Nicolas Fabert'
    foreach ($role in $script:TsGuiRoles) { [void]$controls.Role.Items.Add((New-TsGuiRoleCard -Role $role)) }
    foreach ($value in '1', '2') { [void]$controls.Sites.Items.Add($value) }
    foreach ($value in $script:TsFailures.Values) { [void]$controls.Failure.Items.Add($value) }
    foreach ($value in $script:TsQueueVolumes.Values) { [void]$controls.QueueVolume.Items.Add($value) }
    foreach ($value in $script:TsJournalScopes.Values) { [void]$controls.JournalScope.Items.Add($value) }
    foreach ($value in $script:TsJournalDestinations.Values) { [void]$controls.JournalDestination.Items.Add($value) }
    foreach ($value in $script:TsPeakRateUnits.Values) { [void]$controls.PeakRateUnit.Items.Add($value) }
    foreach ($processor in (Get-TsProcessorCatalog)) { [void]$controls.TargetProcessor.Items.Add($processor.Name) }
    $reference = Get-TsReference
    foreach ($pair in $script:TsGuiSizeCombos) {
        foreach ($disk in (Get-TsDiskCatalog -Role $pair.Role)) { [void]$controls[$pair.Type].Items.Add($disk.Name) }
    }
    foreach ($raid in @($reference.Raid.Keys | Sort-Object)) { [void]$controls.QueueRaid.Items.Add($raid); [void]$controls.SystemRaid.Items.Add($raid) }
    $controls.Flows.Columns[1].ItemsSource = [string[]]@($script:TsDirections.Values)

    $table = [Data.DataTable]::new('Flows')
    foreach ($column in 'Name', 'Direction', 'MessagesPerDay', 'AverageSizeKB', 'FanOut') { [void]$table.Columns.Add($column, [string]) }
    [void]$table.Columns.Add('Held', [bool])
    $controls.Flows.ItemsSource = $table.DefaultView

    $tiles = [ordered]@{}
    foreach ($tile in @(@('Servers', 'Serveurs'), @('Cpu', 'Processeur'), @('Ram', 'Mémoire'), @('Rate', 'Débit cible'),
            @('System', 'Disque système'), @('Queue', 'Volume de la file'), @('Iops', 'IOPS de la file'), @('Network', 'Réseau'))) {
        $tiles[$tile[0]] = New-TsGuiTile -Label $tile[1]
        [void]$controls.Tiles.Children.Add($tiles[$tile[0]].Border)
    }
    $checks = [Collections.ObjectModel.ObservableCollection[object]]::new()
    $controls.Checks.ItemsSource = $checks
    $config = [Collections.ObjectModel.ObservableCollection[object]]::new()
    $controls.Config.ItemsSource = $config

    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(350)
    $script:Gui = @{
        Form = $window; Controls = $controls; Theme = $look; Table = $table; Tiles = $tiles; ChecksList = $checks; ConfigList = $config; Timer = $timer
        OutputPath = $OutputPath; Calibration = $null; CalibrationPath = ''; Role = 'Edge'; Result = $null; Loading = $false; LastReport = $null; LastSynthesis = $null; LastFolder = $null; ScenarioPath = $null; Notes = ''
    }
    $timer.Add_Tick({ $script:Gui.Timer.Stop(); Update-TsGuiResult })

    $changed = { Request-TsGuiUpdate }
    foreach ($field in $script:TsGuiFields) { $controls[$field.Name].Add_TextChanged($changed) }
    foreach ($name in 'Sites', 'Failure', 'QueueRaid', 'SystemRaid', 'DiskSize', 'SystemDiskSize', 'JournalScope', 'JournalDestination', 'PeakRateUnit') { $controls[$name].Add_SelectionChanged($changed) }
    $controls.QueueVolume.Add_SelectionChanged({ if ($script:Gui.Loading) { return }; Update-TsGuiState; Request-TsGuiUpdate })
    foreach ($pair in $script:TsGuiSizeCombos) {
        $controls[$pair.Type].Add_SelectionChanged({
                param($sender)
                if ($script:Gui.Loading) { return }
                $pair = $script:TsGuiSizeCombos | Where-Object { $_.Type -eq $sender.Name } | Select-Object -First 1
                Set-TsGuiSizes -Size $pair.Size -Type ([string]$sender.SelectedItem) -Role $pair.Role -Info $pair.Info
                Request-TsGuiUpdate
            })
        [void]$controls[$pair.Size].AddHandler([Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [Windows.Controls.TextChangedEventHandler]$changed)
    }
    # A processor of the list gives its SPECint per core; a name typed by hand keeps the value entered.
    $controls.TargetProcessor.Add_SelectionChanged({
            if ($script:Gui.Loading) { return }
            $name = [string]$script:Gui.Controls.TargetProcessor.SelectedItem
            $processor = @(Get-TsProcessorCatalog | Where-Object { $_.Name -eq $name }) | Select-Object -First 1
            if ($processor) { $script:Gui.Controls.TargetSpec.Text = Format-TsGuiNumber $processor.SpecIntRatePerCore }
            Request-TsGuiUpdate
        })
    [void]$controls.TargetProcessor.AddHandler([Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [Windows.Controls.TextChangedEventHandler]$changed)
    $controls.Shadow.Add_Click($changed)
    $controls.Dag.Add_Click($changed)
    $controls.EvenVcpu.Add_Click($changed)
    $controls.JournalHeld.Add_Click($changed)
    $controls.JournalEnabled.Add_Click({ Update-TsGuiState; Request-TsGuiUpdate })
    $controls.Virtual.Add_Click({ Update-TsGuiState; Request-TsGuiUpdate })
    $controls.Physical.Add_Click({ Update-TsGuiState; Request-TsGuiUpdate })
    $controls.Role.Add_SelectionChanged({ Switch-TsGuiRole; Update-TsGuiState; Request-TsGuiUpdate })
    $table.Add_ColumnChanged($changed)
    $table.Add_RowChanged($changed)
    $table.Add_RowDeleted($changed)
    $controls.ImportLogReport.Add_Click({ Invoke-TsGuiLogReport })
    $controls.AddFlow.Add_Click({ Add-TsGuiFlow -Flow ([ordered]@{ Name = 'Nouveau flux'; Direction = 'Inbound'; MessagesPerDay = 0; AverageSizeKB = 75; FanOut = 1; HeldDuringOutage = $true }) })
    $controls.RemoveFlow.Add_Click({
            $view = $script:Gui.Controls.Flows.SelectedItem
            if ($view) { $view.Row.Delete(); $script:Gui.Table.AcceptChanges() }
        })
    $controls.ImportCalibration.Add_Click({ Invoke-TsGuiCalibration })
    $controls.RemoveCalibration.Add_Click({ Set-TsGuiCalibration -Calibration $null -Path ''; Request-TsGuiUpdate })
    $controls.New.Add_Click({ Set-TsGuiScenario -Scenario (Get-TsDefaultScenario -Role $script:Gui.Role) -KeepCalibration; $script:Gui.ScenarioPath = $null })
    $controls.Open.Add_Click({ Invoke-TsGuiOpen })
    $controls.Save.Add_Click({ Invoke-TsGuiSave })
    $controls.Report.Add_Click({ Invoke-TsGuiReport })
    $controls.OpenReport.Add_Click({ if ($script:Gui.LastReport) { Start-Process -FilePath $script:Gui.LastReport } })
    $controls.OpenSynthesis.Add_Click({ if ($script:Gui.LastSynthesis) { Start-Process -FilePath $script:Gui.LastSynthesis } })
    $controls.OpenFolder.Add_Click({ if ($script:Gui.LastFolder) { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($script:Gui.LastFolder)`"" } })

    # The window fits the screen where it opens (small laptop screen at 150 %); the form scrolls.
    $area = [Windows.SystemParameters]::WorkArea
    $window.Width = [Math]::Min($window.Width, $area.Width)
    $window.Height = [Math]::Min($window.Height, $area.Height)
    $window.MinWidth = [Math]::Min($window.MinWidth, $area.Width)
    $window.MinHeight = [Math]::Min($window.MinHeight, $area.Height)

    Set-TsGuiScenario -Scenario $Scenario
    $controls.Footer.Text = "Rapports : $OutputPath"
    [pscustomobject]@{ Form = $window; Controls = $controls; Table = $table; Tiles = $tiles; Checks = $checks; Config = $config }
}

function Request-TsGuiUpdate {
    <# Recalculates a moment after the last change (one computation for a burst of keystrokes). #>
    if (-not $script:Gui -or $script:Gui.Loading) { return }
    $script:Gui.Timer.Stop()
    $script:Gui.Timer.Start()
}

function Add-TsGuiFlow {
    param([Parameter(Mandatory = $true)][object]$Flow)
    $row = $script:Gui.Table.NewRow()
    $row['Name'] = [string](Get-TsField $Flow 'Name' '')
    $direction = [string](Get-TsField $Flow 'Direction' 'Inbound')
    if ($script:TsDirections.Contains($direction)) { $direction = $script:TsDirections[$direction] }
    $row['Direction'] = $direction
    $row['MessagesPerDay'] = Format-TsGuiNumber (Get-TsField $Flow 'MessagesPerDay' 0)
    $row['AverageSizeKB'] = Format-TsGuiNumber (Get-TsField $Flow 'AverageSizeKB' 75)
    $row['FanOut'] = Format-TsGuiNumber (Get-TsField $Flow 'FanOut' 1)
    $row['Held'] = [bool](Get-TsField $Flow 'HeldDuringOutage' $true)
    $script:Gui.Table.Rows.Add($row)
    $script:Gui.Table.AcceptChanges()
}

function Set-TsGuiCalibration {
    <#
        Profile of the form: an imported profile (measured on a server of the customer), or none, in which case
        the reference profile of the role is used. A reference profile embedded in a saved scenario or report
        counts as none: the window always shows the reference of this version of the tool.
    #>
    param([AllowNull()][object]$Calibration, [string]$Path = '')

    $g = $script:Gui
    if ($Calibration -and [bool](Get-TsField $Calibration 'Reference' $false)) { $Calibration = $null; $Path = '' }
    $g.Calibration = $Calibration
    $g.CalibrationPath = $Path
    $c = $g.Controls
    $shown = $Calibration
    if (-not $shown) { $shown = Get-TsReferenceProfile -Role $g.Role }
    $steps = @($shown.Steps).Count
    $server = $shown.Server
    $detail = '{0} · {1} processeurs logiques, {2} Go · {3} palier(s){4}' -f $(if ($server.Name) { $server.Name } else { 'serveur de référence' }),
        (Format-TsNumber $server.LogicalProcessors 0), (Format-TsNumber $server.MemoryGB 0), $steps, $(if ($shown.MeasuredAt) { ' · mesuré le ' + $shown.MeasuredAt } else { '' })
    if ($Calibration) {
        $c.CalibrationIcon.Text = [string][char]0xE73E
        $c.CalibrationIcon.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TsSuccess')
        $c.CalibrationStatus.Text = 'Profil importé « {0} »{1} · {2}' -f $Calibration.Name, $(if ($Calibration.Role) { ' (' + $script:TsRoles[$Calibration.Role] + ')' } else { '' }), $detail
        $c.RemoveCalibration.IsEnabled = $true
    }
    else {
        $c.CalibrationIcon.Text = [string][char]0xE946
        $c.CalibrationIcon.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TsInfo')
        $c.CalibrationStatus.Text = '{0} · {1} processeurs logiques, {2} Go · {3} palier(s){4} · générique : importer le profil d’’un serveur du client pour l’’affiner.' -f $shown.Name,
            (Format-TsNumber $server.LogicalProcessors 0), (Format-TsNumber $server.MemoryGB 0), $steps, $(if ($shown.MeasuredAt) { ', mesuré le ' + $shown.MeasuredAt } else { '' })
        $c.RemoveCalibration.IsEnabled = $false
        if ($Path) {
            # Profile named by the scenario but not found: the reference is used, the path is kept so that the report warns.
            $c.CalibrationIcon.Text = [string][char]0xE7BA
            $c.CalibrationIcon.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TsCaution')
            $c.CalibrationStatus.Text = 'Profil « {0} » introuvable : profil de référence « {1} » utilisé à la place.' -f $Path, $shown.Name
            $c.RemoveCalibration.IsEnabled = $true
        }
    }
}

function Set-TsGuiScenario {
    <# Shows a scenario in the form (complete or partial; the defaults of its role fill the rest). #>
    param([Parameter(Mandatory = $true)][object]$Scenario, [switch]$KeepCalibration)

    $g = $script:Gui
    $s = ConvertTo-TsScenario -Scenario $Scenario
    $c = $g.Controls
    $g.Loading = $true
    try {
        $g.Role = $s.Role
        $g.Notes = $s.Notes
        $c.Role.SelectedIndex = [Array]::FindIndex([object[]]$script:TsGuiRoles, [Predicate[object]] { param($x) $x.Role -eq $s.Role })
        $c.Virtual.IsChecked = $s.Deployment -eq 'Virtual'
        $c.Physical.IsChecked = $s.Deployment -eq 'Physical'
        foreach ($field in $script:TsGuiFields) {
            if ($field.ContainsKey('Group')) { $c[$field.Name].Text = Format-TsGuiNumber $s[$field.Group][$field.Key] }
            else { $c[$field.Name].Text = [string]$s[$field.Key] }
            $c[$field.Name].ClearValue([Windows.Controls.Control]::BorderBrushProperty)
        }
        $c.Sites.SelectedItem = [string][int]$s.Topology.Sites
        if ($null -eq $c.Sites.SelectedItem) { $c.Sites.SelectedIndex = 0 }
        $c.Failure.SelectedItem = $script:TsFailures[$s.Topology.Failure]
        $c.QueueVolume.SelectedItem = $script:TsQueueVolumes[$s.Storage.QueueVolume]
        $c.Shadow.IsChecked = [bool]$s.Resilience.ShadowRedundancy
        $c.Dag.IsChecked = [bool]$s.Topology.Dag
        $c.EvenVcpu.IsChecked = [bool]$s.Compute.EvenVcpu
        $c.TargetProcessor.Text = [string]$s.Compute.TargetProcessor
        $c.JournalEnabled.IsChecked = [bool]$s.Journaling.Enabled
        $c.JournalScope.SelectedItem = $script:TsJournalScopes[$s.Journaling.Scope]
        $c.JournalDestination.SelectedItem = $script:TsJournalDestinations[$s.Journaling.Destination]
        $c.JournalHeld.IsChecked = [bool]$s.Journaling.HeldDuringOutage
        $c.PeakRateUnit.SelectedItem = $script:TsPeakRateUnits[$s.Load.PeakRateUnit]
        foreach ($pair in $script:TsGuiSizeCombos) {
            $c[$pair.Type].SelectedItem = $s.Physical[$pair.TypeKey]
            Set-TsGuiSizes -Size $pair.Size -Type $s.Physical[$pair.TypeKey] -Role $pair.Role -Info $pair.Info -SizeGB $s.Physical[$pair.SizeKey]
        }
        $c.QueueRaid.SelectedItem = $s.Physical.QueueRaid
        $c.SystemRaid.SelectedItem = $s.Physical.SystemRaid
        $g.Table.Rows.Clear()
        foreach ($flow in $s.Flows) { Add-TsGuiFlow -Flow $flow }
        if (-not $KeepCalibration) { Set-TsGuiCalibration -Calibration $s.Calibration -Path $s.CalibrationPath }
        else { Set-TsGuiCalibration -Calibration $g.Calibration -Path $g.CalibrationPath }
    }
    finally { $g.Loading = $false }
    Update-TsGuiState
    Update-TsGuiResult
}

function Switch-TsGuiRole {
    <# New role: the storage values still at the defaults of the old role take the defaults of the new one. #>
    $g = $script:Gui
    if ($g.Loading) { return }
    $index = $g.Controls.Role.SelectedIndex
    if ($index -lt 0) { return }
    $role = $script:TsGuiRoles[$index].Role
    if ($role -eq $g.Role) { return }
    $old = Get-TsDefaultScenario -Role $g.Role
    $new = Get-TsDefaultScenario -Role $role
    foreach ($field in @($script:TsGuiFields | Where-Object { $_.ContainsKey('Group') -and $_.Group -eq 'Storage' })) {
        $box = $g.Controls[$field.Name]
        if ($box.Text -eq (Format-TsGuiNumber $old.Storage[$field.Key])) { $box.Text = Format-TsGuiNumber $new.Storage[$field.Key] }
    }
    $g.Role = $role
    # The reference profile follows the role; an imported profile is kept (the report warns if its role differs).
    Set-TsGuiCalibration -Calibration $g.Calibration -Path $g.CalibrationPath
}

function Update-TsGuiState {
    <# What depends on the role and the deployment: Mailbox panel, physical server card, hints. #>
    $g = $script:Gui
    $c = $g.Controls
    $edge = $g.Role -eq 'Edge'
    $physical = [bool]$c.Physical.IsChecked
    $c.MailboxPanel.IsEnabled = -not $edge
    $c.MailboxPanel.Opacity = $(if ($edge) { 0.45 } else { 1 })
    $c.EdgeNotice.Visibility = $(if ($edge) { 'Visible' } else { 'Collapsed' })
    $c.JournalPanel.IsEnabled = -not $edge
    $c.JournalPanel.Opacity = $(if ($edge) { 0.45 } else { 1 })
    $c.JournalNotice.Visibility = $(if ($edge) { 'Visible' } else { 'Collapsed' })
    foreach ($name in 'JournalScope', 'JournalDestination', 'JournalPercent', 'JournalRecipients', 'JournalOverhead', 'JournalHeld') { $c[$name].IsEnabled = [bool]$c.JournalEnabled.IsChecked }
    $c.PhysicalCard.Visibility = $(if ($physical) { 'Visible' } else { 'Collapsed' })
    foreach ($name in 'EvenVcpu', 'VcpuRatio', 'MemoryReserved') { $c[$name].IsEnabled = -not $physical }
    $c.RoundingGB.IsEnabled = -not $physical
    $dedicatedQueue = (Get-TsGuiKey $script:TsQueueVolumes $c.QueueVolume.SelectedItem) -eq 'Dedicated'
    foreach ($name in 'DiskType', 'DiskSize', 'DiskIops', 'QueueRaid') { $c[$name].IsEnabled = $dedicatedQueue }
    $c.DiskCatalogInfo.Opacity = $(if ($dedicatedQueue) { 1 } else { 0.45 })
    $c.RoleHint.Text = $(if ($edge) {
            'Edge Transport : file d’’attente = transit + panne du saut suivant ; deux cartes réseau (interne et externe). Ni Safety Net ni redondance shadow.'
        }
        else {
            'Mailbox (transport) : la file compte Safety Net et, avec au moins deux serveurs restants, les copies shadow détenues pour les autres serveurs, même sans boîte aux lettres.'
        })
}

function Read-TsGuiScenario {
    <# The scenario of the form. Returns Scenario and Errors (French messages); invalid fields are outlined in red. #>
    $g = $script:Gui
    $c = $g.Controls
    $errors = [Collections.Generic.List[string]]::new()
    $critical = $g.Form.TryFindResource('TsCritical')
    $s = Get-TsDefaultScenario -Role $g.Role
    $s.Deployment = $(if ($c.Physical.IsChecked) { 'Physical' } else { 'Virtual' })
    $s.Notes = [string]$g.Notes
    foreach ($field in $script:TsGuiFields) {
        $box = $c[$field.Name]
        if (-not $field.ContainsKey('Group')) { $s[$field.Key] = $box.Text; continue }
        try {
            $s[$field.Group][$field.Key] = ConvertTo-TsNumber $box.Text $field.Label
            $box.ClearValue([Windows.Controls.Control]::BorderBrushProperty)
        }
        catch {
            $errors.Add($_.Exception.Message)
            $box.BorderBrush = $critical
        }
    }
    $s.Topology.Sites = [double]([string]$c.Sites.SelectedItem)
    $s.Topology.Failure = Get-TsGuiKey $script:TsFailures $c.Failure.SelectedItem
    $s.Storage.QueueVolume = Get-TsGuiKey $script:TsQueueVolumes $c.QueueVolume.SelectedItem
    $s.Resilience.ShadowRedundancy = [bool]$c.Shadow.IsChecked
    $s.Topology.Dag = [bool]$c.Dag.IsChecked
    $s.Compute.EvenVcpu = [bool]$c.EvenVcpu.IsChecked
    $s.Compute.TargetProcessor = ([string]$c.TargetProcessor.Text).Trim()
    $s.Journaling.Enabled = [bool]$c.JournalEnabled.IsChecked
    $s.Journaling.Scope = Get-TsGuiKey $script:TsJournalScopes $c.JournalScope.SelectedItem
    $s.Journaling.Destination = Get-TsGuiKey $script:TsJournalDestinations $c.JournalDestination.SelectedItem
    $s.Journaling.HeldDuringOutage = [bool]$c.JournalHeld.IsChecked
    $s.Load.PeakRateUnit = Get-TsGuiKey $script:TsPeakRateUnits $c.PeakRateUnit.SelectedItem
    $s.Physical.QueueRaid = [string]$c.QueueRaid.SelectedItem
    $s.Physical.SystemRaid = [string]$c.SystemRaid.SelectedItem
    foreach ($pair in $script:TsGuiSizeCombos) {
        $s.Physical[$pair.TypeKey] = [string]$c[$pair.Type].SelectedItem
        $box = $c[$pair.Size]
        try {
            $s.Physical[$pair.SizeKey] = ConvertTo-TsNumber $box.Text $pair.Label
            $box.ClearValue([Windows.Controls.Control]::BorderBrushProperty)
        }
        catch {
            $errors.Add($_.Exception.Message)
            $box.BorderBrush = $critical
        }
    }
    $s.Flows = @(foreach ($row in $g.Table.Rows) {
            if ($row.RowState -eq [Data.DataRowState]::Deleted) { continue }
            [ordered]@{
                Name = [string]$row['Name']; Direction = [string]$row['Direction']; MessagesPerDay = [string]$row['MessagesPerDay']
                AverageSizeKB = [string]$row['AverageSizeKB']; FanOut = [string]$row['FanOut']; HeldDuringOutage = $(if ($row['Held'] -is [DBNull]) { $false } else { [bool]$row['Held'] })
            }
        })
    $s.Calibration = $g.Calibration
    $s.CalibrationPath = $g.CalibrationPath
    $scenario = $null
    if ($errors.Count -eq 0) {
        try { $scenario = ConvertTo-TsScenario -Scenario $s }
        catch { $errors.Add($_.Exception.Message) }
    }
    [pscustomobject]@{ Scenario = $scenario; Errors = $errors.ToArray() }
}

function Set-TsGuiTile {
    param([Parameter(Mandatory = $true)][string]$Key, [string]$Value, [string]$Note, [switch]$Missing)
    $tile = $script:Gui.Tiles[$Key]
    $tile.Value.Text = $Value
    $tile.Note.Text = $Note
    $brush = if ($Missing) { 'TsCaution' } else { 'TextFillColorPrimaryBrush' }
    $tile.Value.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $brush)
}

function Set-TsGuiStatus {
    param([ValidateSet('Ready', 'Warning', 'Error', 'Info')][string]$State, [string]$Text)
    $c = $script:Gui.Controls
    $c.Status.Text = $Text
    $background = switch ($State) { 'Ready' { 'TsSuccessBackground' } 'Warning' { 'TsCautionBackground' } 'Error' { 'TsCriticalBackground' } default { 'TsInfoBackground' } }
    $c.StatusPill.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, $background)
}

function Update-TsGuiResult {
    <# Recalculates the scenario of the form and shows the server, the configuration and the checks. #>
    $g = $script:Gui
    if (-not $g -or $g.Loading) { return }
    $form = $g.Form
    $brushes = @{ Error = $form.TryFindResource('TsCritical'); Warning = $form.TryFindResource('TsCaution'); Info = $form.TryFindResource('TsInfo') }
    $primary = $form.TryFindResource('TextFillColorPrimaryBrush')
    $glyphs = @{ Error = [string][char]0xE783; Warning = [string][char]0xE7BA; Info = [string][char]0xE946 }
    $g.ChecksList.Clear()
    $g.ConfigList.Clear()
    $read = Read-TsGuiScenario
    # The share of the peak hour is computed from the measured peak rate when there is one.
    $rateText = ([string]$g.Controls.PeakRate.Text).Trim()
    $g.Controls.PeakHour.IsEnabled = -not ($rateText -and $rateText -notmatch '^0+([.,]0*)?$')
    $result = $null
    $errors = @($read.Errors)
    if ($errors.Count -eq 0) {
        try { $result = Invoke-TsSizing -Scenario $read.Scenario }
        catch { $errors = @($_.Exception.Message) }
    }
    $g.Result = $result
    if (-not $result -or -not $result.Valid) {
        foreach ($tile in @($g.Tiles.Keys)) { Set-TsGuiTile -Key $tile -Value '—' -Note '' }
        foreach ($message in $errors) { $g.ChecksList.Add([pscustomobject]@{ Glyph = $glyphs.Error; Brush = $brushes.Error; Text = $message }) }
        if ($result) { foreach ($check in $result.Checks) { $g.ChecksList.Add([pscustomobject]@{ Glyph = $glyphs[$check.Level]; Brush = $brushes[$check.Level]; Text = $check.Message }) } }
        $g.Controls.ResultSubtitle.Text = 'Le scénario contient une erreur : la corriger pour obtenir le dimensionnement.'
        $g.Controls.DaySummary.Text = ''
        Set-TsGuiStatus Error 'À corriger'
        $g.Controls.Report.IsEnabled = $false
        return
    }
    $s = $result.Summary
    $g.Controls.Report.IsEnabled = $true
    $g.Controls.ResultSubtitle.Text = '{0} · {1} · {2} serveur(s), dimensionné pour : {3} ({4} restant(s)) · {5} messages par jour et par serveur, {6} Ko en moyenne' -f `
        $s.RoleLabel, $s.DeploymentLabel, $s.Servers, $s.FailureLabel.ToLower(), $s.Alive, (Format-TsNumber $s.MessagesPerDayPerServer 0), (Format-TsNumber $s.AverageSizeKB 0)
    Set-TsGuiTile Servers ([string]$s.Servers) ('{0} restant(s) en panne' -f $s.Alive)
    if ($null -ne $s.Cores) { Set-TsGuiTile Cpu ('{0} {1}' -f $s.Cores, $s.CoreUnit) ('{0} % au débit cible' -f (Format-TsNumber ($s.CpuUtilization * 100) 0)) }
    else { Set-TsGuiTile Cpu 'À calibrer' 'calibration requise' -Missing }
    if ($null -ne $s.RamGB) { Set-TsGuiTile Ram ('{0} Go' -f (Format-TsNumber $s.RamGB 0)) 'back pressure respecté' }
    else { Set-TsGuiTile Ram 'À calibrer' 'calibration requise' -Missing }
    Set-TsGuiTile Rate ('{0} msg/s' -f (Format-TsNumber $s.RateDesign 1)) ('{0} msg/h · max {1}{2}' -f (Format-TsNumber ($s.RateDesign * 3600) 0), (Format-TsNumber $s.RateMax 1), $(if ($s.RateMaxExtrapolated) { ' (extrapolé)' } else { '' }))
    $g.Controls.DaySummary.Text = 'Par serveur : {0} msg/h en moyenne pendant les {1} h ouvrées ({2} msg/s), pointe {3} msg/h ({4} msg/s) pendant {5} h, soit {6} % du jour par heure de pointe{7}.' -f `
        (Format-TsNumber ($s.RateWorking * 3600) 0), (Format-TsNumber $s.WorkingHours 0), (Format-TsNumber $s.RateWorking 2), (Format-TsNumber ($s.RatePeak * 3600) 0), (Format-TsNumber $s.RatePeak 2),
        (Format-TsNumber $s.PeakHours 0), (Format-TsNumber $s.PeakHourPercent 1), $(if ($s.PeakFromRate) { ', calculé depuis le débit de pointe mesuré' } else { '' })
    Set-TsGuiTile System ('{0} Go' -f (Format-TsNumber $s.SystemGB 0)) $(if ($s.QueueOnSystem) { 'file comprise' } else { 'système, Exchange, journaux' })
    if ($s.QueueOnSystem) { Set-TsGuiTile Queue 'Système' ('mail.que {0} Go' -f (Format-TsNumber $s.MailQueGB 1)) }
    else { Set-TsGuiTile Queue ('{0} Go' -f (Format-TsNumber $s.QueueVolumeGB 0)) ('mail.que {0} Go' -f (Format-TsNumber $s.MailQueGB 1)) }
    if ($null -ne $s.Iops) { Set-TsGuiTile Iops ('{0}' -f (Format-TsNumber $s.Iops 0)) $(if ($null -ne $s.QueueWriteMBps) { 'et {0} Mo/s en écriture' -f (Format-TsNumber $s.QueueWriteMBps 1) } else { 'au débit cible' }) }
    else { Set-TsGuiTile Iops 'À calibrer' 'calibration requise' -Missing }
    Set-TsGuiTile Network ('{0} Mbit/s' -f (Format-TsNumber $s.NetworkMbps 1)) ('{0} % de la carte' -f (Format-TsNumber $s.LinkUse 1))
    foreach ($row in $result.Config) {
        $brush = if ($row.Status -eq 'ok') { $primary } else { $brushes.Warning }
        $g.ConfigList.Add([pscustomobject]@{ Component = $row.Component; Value = $row.Value; Detail = $row.Detail; Brush = $brush })
    }
    foreach ($check in $result.Checks) { $g.ChecksList.Add([pscustomobject]@{ Glyph = $glyphs[$check.Level]; Brush = $brushes[$check.Level]; Text = $check.Message }) }
    $warnings = @($result.Checks | Where-Object { $_.Level -ne 'Info' }).Count
    $hasError = @($result.Checks | Where-Object { $_.Level -eq 'Error' }).Count -gt 0
    if ($hasError) { Set-TsGuiStatus Error 'Erreur à corriger' }
    elseif ($warnings -gt 0) { Set-TsGuiStatus Warning ('{0} point(s) d’’attention' -f $warnings) }
    else { Set-TsGuiStatus Ready 'Complet' }
}

function Import-TsGuiLogReport {
    <#
        Puts the traffic of an Exchange Log Report in the form (flows, peak hour, messages per session, TLS);
        the other values are kept. Returns the French summary of the import.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [ValidateSet('Average', 'Busiest')][string]$Day = 'Average')

    $g = $script:Gui
    $read = Read-TsGuiScenario
    if ($read.Errors.Count -gt 0) { throw ("Corriger d’’abord le scénario :`n" + ($read.Errors -join "`n")) }
    $import = Import-TsLogReport -Path $Path -Day $Day
    $scenario = Update-TsScenarioFromLogReport -Scenario $read.Scenario -LogReport $import -WarningAction SilentlyContinue
    Set-TsGuiScenario -Scenario $scenario
    $g.Controls.Footer.Text = "Trafic importé : $($import.Files.Messages)"
    return @(Format-TsLogReportSummary -LogReport $import -ScenarioRole $scenario.Role)
}

function Invoke-TsGuiLogReport {
    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title = 'Rapport détaillé Exchange Log Report'
    $dialog.Filter = 'Messages Exchange Log Report (*-Messages.csv)|*-Messages.csv|Fichiers CSV (*.csv)|*.csv'
    if (-not $dialog.ShowDialog($script:Gui.Form)) { return }
    $form = $script:Gui.Form
    $form.Cursor = [Windows.Input.Cursors]::Wait
    try {
        $lines = Import-TsGuiLogReport -Path $dialog.FileName
        $form.Cursor = $null
        [void][Windows.MessageBox]::Show($form, ($lines -join [Environment]::NewLine), 'Transport Sizer · Exchange Log Report', 'OK', 'Information')
    }
    catch {
        $form.Cursor = $null
        [void][Windows.MessageBox]::Show($form, $_.Exception.Message, 'Transport Sizer', 'OK', 'Warning')
    }
}

function Invoke-TsGuiCalibration {
    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title = 'Profil de calibration'
    $dialog.Filter = 'Profil de calibration (*.json)|*.json|Tous les fichiers (*.*)|*.*'
    $examples = Join-Path $script:ToolRoot 'examples'
    if (Test-Path -LiteralPath $examples) { $dialog.InitialDirectory = $examples }
    if (-not $dialog.ShowDialog($script:Gui.Form)) { return }
    try {
        $calibration = Import-TsCalibration -Path $dialog.FileName
        Set-TsGuiCalibration -Calibration $calibration -Path $dialog.FileName
        Request-TsGuiUpdate
    }
    catch { [void][Windows.MessageBox]::Show($script:Gui.Form, $_.Exception.Message, 'Transport Sizer', 'OK', 'Warning') }
}

function Invoke-TsGuiOpen {
    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title = 'Ouvrir un scénario'
    $dialog.Filter = 'Scénario Transport Sizer (*.json)|*.json|Tous les fichiers (*.*)|*.*'
    $examples = Join-Path $script:ToolRoot 'examples'
    if (Test-Path -LiteralPath $examples) { $dialog.InitialDirectory = $examples }
    if (-not $dialog.ShowDialog($script:Gui.Form)) { return }
    try {
        Set-TsGuiScenario -Scenario (Import-TsScenario -Path $dialog.FileName)
        $script:Gui.ScenarioPath = $dialog.FileName
        $script:Gui.Controls.Footer.Text = "Scénario : $($dialog.FileName)"
    }
    catch { [void][Windows.MessageBox]::Show($script:Gui.Form, $_.Exception.Message, 'Transport Sizer', 'OK', 'Warning') }
}

function Invoke-TsGuiSave {
    $read = Read-TsGuiScenario
    if ($read.Errors.Count -gt 0) {
        [void][Windows.MessageBox]::Show($script:Gui.Form, ($read.Errors -join [Environment]::NewLine), 'Transport Sizer', 'OK', 'Warning')
        return
    }
    $dialog = [Microsoft.Win32.SaveFileDialog]::new()
    $dialog.Title = 'Enregistrer le scénario'
    $dialog.Filter = 'Scénario Transport Sizer (*.json)|*.json'
    $dialog.FileName = (Get-TsSafeName $read.Scenario.Name) + '.json'
    if ($script:Gui.ScenarioPath) { $dialog.InitialDirectory = Split-Path -Parent $script:Gui.ScenarioPath; $dialog.FileName = Split-Path -Leaf $script:Gui.ScenarioPath }
    if (-not $dialog.ShowDialog($script:Gui.Form)) { return }
    try {
        [void](Export-TsScenario -Scenario $read.Scenario -Path $dialog.FileName)
        $script:Gui.ScenarioPath = $dialog.FileName
        $script:Gui.Controls.Footer.Text = "Scénario enregistré : $($dialog.FileName)"
    }
    catch { [void][Windows.MessageBox]::Show($script:Gui.Form, $_.Exception.Message, 'Transport Sizer', 'OK', 'Warning') }
}

function Invoke-TsGuiReport {
    <# Same reports as the command line: the customer summary is opened in the browser, the technical report stays a click away. #>
    param([switch]$NoOpen)

    $g = $script:Gui
    $g.Timer.Stop()
    Update-TsGuiResult
    if (-not $g.Result -or -not $g.Result.Valid) { return $null }
    try {
        $files = Export-TsReport -Result $g.Result -OutputPath $g.OutputPath
        $g.LastReport = $files.Html
        $g.LastSynthesis = $files.Synthesis
        $g.LastFolder = $files.Folder
        $g.Controls.OpenReport.IsEnabled = $true
        $g.Controls.OpenSynthesis.IsEnabled = $true
        $g.Controls.OpenFolder.IsEnabled = $true
        $g.Controls.Footer.Text = "Rapports : $($files.Folder)"
        if (-not $NoOpen) { Start-Process -FilePath $files.Synthesis; Start-Process -FilePath $files.Html }
        return $files
    }
    catch {
        [void][Windows.MessageBox]::Show($g.Form, $_.Exception.Message, 'Transport Sizer', 'OK', 'Warning')
        return $null
    }
}

function Show-TsSizerGui {
    <#
    .SYNOPSIS
        Opens the window with a scenario (default: Edge). Reports go to OutputPath (default: reports).
    #>
    [CmdletBinding()]
    param([object]$Scenario, [string]$OutputPath)

    $form = New-TsSizerForm -Scenario $Scenario -OutputPath $OutputPath
    # Ctrl+C in the console would stop the command that owns the window: its handlers could not run any more.
    $previousCtrlC = $null
    try { if (-not [Console]::IsInputRedirected) { $previousCtrlC = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true } } catch { $previousCtrlC = $null }
    try {
        [void]$form.Form.ShowDialog()
    }
    finally {
        if ($script:Gui -and $script:Gui.Timer) { $script:Gui.Timer.Stop() }
        if ($null -ne $previousCtrlC) { try { [Console]::TreatControlCAsInput = $previousCtrlC } catch { } }
        $script:Gui = $null
    }
}