#define AppName "焦点哔哩"
#define AppPublisher "L1Xu4n"
#define AppExecutable "FocuBili.exe"

#ifndef AppVersion
  #error AppVersion must be supplied by build_windows_packages.ps1.
#endif

#ifndef AppBuild
  #error AppBuild must be supplied by build_windows_packages.ps1.
#endif

#ifndef SourceDir
  #error SourceDir must be supplied by build_windows_packages.ps1.
#endif

#ifndef OutputDir
  #error OutputDir must be supplied by build_windows_packages.ps1.
#endif

[Setup]
AppId={{8B7E1A0E-C692-4BA8-A2BA-B0F78ED60A26}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL=https://github.com/L1Xu4n/FocuBili
AppSupportURL=https://github.com/L1Xu4n/FocuBili/issues
AppUpdatesURL=https://github.com/L1Xu4n/FocuBili/releases
DefaultDirName={localappdata}\Programs\FocuBili
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=FocuBili-v{#AppVersion}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExecutable}
LicenseFile=..\..\LICENSE
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=auto
CloseApplications=yes
RestartApplications=no
AppMutex=FocuBili.SingleInstance
SetupLogging=yes
VersionInfoCompany=FocuBili
VersionInfoDescription=焦点哔哩 Windows 安装程序
VersionInfoProductName=焦点哔哩
VersionInfoProductVersion={#AppVersion}
VersionInfoVersion={#AppVersion}.{#AppBuild}
ChangesAssociations=no
ChangesEnvironment=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Default.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[LangOptions]
chinesesimplified.LanguageName=简体中文
chinesesimplified.LanguageID=$0804
chinesesimplified.LanguageCodePage=0
chinesesimplified.DialogFontName=Microsoft YaHei UI
chinesesimplified.WelcomeFontName=Microsoft YaHei UI

[Messages]
chinesesimplified.SetupAppTitle=安装
chinesesimplified.SetupWindowTitle=安装 - %1
chinesesimplified.UninstallAppTitle=卸载
chinesesimplified.UninstallAppFullTitle=卸载 %1
chinesesimplified.InformationTitle=信息
chinesesimplified.ConfirmTitle=确认
chinesesimplified.ErrorTitle=错误
chinesesimplified.SetupLdrStartupMessage=即将安装 %1，是否继续？
chinesesimplified.WindowsVersionNotSupported=当前 Windows 版本不受支持。
chinesesimplified.WinVersionTooLowError=本程序需要 %1 %2 或更高版本。
chinesesimplified.SetupAlreadyRunning=安装程序已经在运行。
chinesesimplified.SetupAppRunningError=检测到 %1 正在运行。%n%n请关闭应用后单击“确定”继续，或单击“取消”退出。
chinesesimplified.UninstallAppRunningError=检测到 %1 正在运行。%n%n请关闭应用后单击“确定”继续，或单击“取消”退出。
chinesesimplified.ExitSetupTitle=退出安装
chinesesimplified.ExitSetupMessage=安装尚未完成。现在退出将不会安装程序。%n%n以后可以重新运行安装程序。%n%n确定退出吗？
chinesesimplified.ButtonBack=< 上一步(&B)
chinesesimplified.ButtonNext=下一步(&N) >
chinesesimplified.ButtonInstall=安装(&I)
chinesesimplified.ButtonOK=确定
chinesesimplified.ButtonCancel=取消
chinesesimplified.ButtonYes=是(&Y)
chinesesimplified.ButtonNo=否(&N)
chinesesimplified.ButtonFinish=完成(&F)
chinesesimplified.ButtonBrowse=浏览(&B)...
chinesesimplified.SelectLanguageTitle=选择安装语言
chinesesimplified.SelectLanguageLabel=请选择安装过程使用的语言。
chinesesimplified.ClickNext=单击“下一步”继续，或单击“取消”退出安装。
chinesesimplified.WelcomeLabel1=欢迎使用 [name] 安装向导
chinesesimplified.WelcomeLabel2=本向导将在你的电脑上安装 [name/ver]。%n%n建议先关闭其他应用，然后继续。
chinesesimplified.WizardLicense=许可协议
chinesesimplified.LicenseLabel=继续前请阅读以下重要信息。
chinesesimplified.LicenseLabel3=继续安装前必须阅读并接受以下许可协议。
chinesesimplified.LicenseAccepted=我接受此协议(&A)
chinesesimplified.LicenseNotAccepted=我不接受此协议(&D)
chinesesimplified.WizardSelectDir=选择安装位置
chinesesimplified.SelectDirDesc=[name] 应安装到哪里？
chinesesimplified.SelectDirLabel3=安装程序会把 [name] 安装到以下文件夹。
chinesesimplified.SelectDirBrowseLabel=单击“下一步”继续；如需更改位置，请单击“浏览”。
chinesesimplified.WizardSelectTasks=选择附加任务
chinesesimplified.SelectTasksDesc=安装时还要执行哪些任务？
chinesesimplified.SelectTasksLabel2=请选择安装 [name] 时需要执行的附加任务，然后单击“下一步”。
chinesesimplified.WizardReady=准备安装
chinesesimplified.ReadyLabel1=安装程序已准备好在你的电脑上安装 [name]。
chinesesimplified.ReadyLabel2a=单击“安装”继续；如需检查或更改设置，请单击“上一步”。
chinesesimplified.ReadyLabel2b=单击“安装”继续。
chinesesimplified.ReadyMemoDir=安装位置：
chinesesimplified.ReadyMemoTasks=附加任务：
chinesesimplified.WizardPreparing=正在准备安装
chinesesimplified.PreparingDesc=安装程序正在准备把 [name] 安装到你的电脑。
chinesesimplified.ApplicationsFound=以下应用正在使用需要更新的文件。建议允许安装程序自动关闭这些应用。
chinesesimplified.CloseApplications=自动关闭应用(&A)
chinesesimplified.DontCloseApplications=不要关闭应用(&D)
chinesesimplified.WizardInstalling=正在安装
chinesesimplified.InstallingLabel=请稍候，安装程序正在把 [name] 安装到你的电脑。
chinesesimplified.FinishedHeadingLabel=[name] 安装向导已完成
chinesesimplified.FinishedLabelNoIcons=[name] 已安装完成。
chinesesimplified.FinishedLabel=[name] 已安装完成，可以通过创建的快捷方式启动。
chinesesimplified.ClickFinish=单击“完成”退出安装程序。
chinesesimplified.SetupAborted=安装没有完成。%n%n请解决问题后重新运行安装程序。
chinesesimplified.StatusClosingApplications=正在关闭应用...
chinesesimplified.StatusCreateDirs=正在创建文件夹...
chinesesimplified.StatusExtractFiles=正在解压文件...
chinesesimplified.StatusCreateIcons=正在创建快捷方式...
chinesesimplified.StatusSavingUninstall=正在保存卸载信息...
chinesesimplified.StatusRunProgram=正在完成安装...
chinesesimplified.ConfirmUninstall=确定要完整移除 %1 及其所有组件吗？
chinesesimplified.UninstallStatusLabel=请稍候，正在从电脑中移除 %1。
chinesesimplified.UninstalledAll=%1 已成功从电脑中移除。
chinesesimplified.WizardUninstalling=卸载状态
chinesesimplified.StatusUninstalling=正在卸载 %1...

[CustomMessages]
chinesesimplified.AdditionalShortcuts=附加快捷方式：
chinesesimplified.CreateDesktopIcon=创建桌面快捷方式
chinesesimplified.LaunchFocuBili=启动焦点哔哩
english.AdditionalShortcuts=Additional shortcuts:
english.CreateDesktopIcon=Create a desktop shortcut
english.LaunchFocuBili=Launch FocuBili

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalShortcuts}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExecutable}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExecutable}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExecutable}"; Description: "{cm:LaunchFocuBili}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
