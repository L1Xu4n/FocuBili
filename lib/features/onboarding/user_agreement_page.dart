import 'package:flutter/material.dart';

/// 保存用户协议一个章节的标题与正文，避免页面布局重复书写。
class _AgreementSection {
  /// 创建一段只读协议章节。
  const _AgreementSection(this.title, this.body);

  final String title;
  final String body;
}

/// 展示首次安装用户须知，并在十秒倒计时结束后开放同意入口。
class UserAgreementPage extends StatelessWidget {
  /// 创建协议页，并接收退出、同意和剩余倒计时状态。
  const UserAgreementPage({
    super.key,
    required this.secondsRemaining,
    required this.accepting,
    required this.exiting,
    required this.onAccept,
    required this.onExit,
  });

  static const List<_AgreementSection> _sections = <_AgreementSection>[
    _AgreementSection(
      '一、非官方项目声明',
      '焦点哔哩是由个人开发者制作的第三方哔哩哔哩客户端，仅用于个人学习、技术研究和专注观看公开视频。\n\n'
          '本应用不是哔哩哔哩官方客户端，与哔哩哔哩及其关联主体不存在隶属、授权、代理、合作或其他官方关系。\n\n'
          '“哔哩哔哩”“bilibili”、相关名称、标识、视频内容及其他权利，归其各自权利人所有。',
    ),
    _AgreementSection(
      '二、服务来源与稳定性',
      '本应用通过哔哩哔哩公开页面、网络服务读取和播放用户有权访问的内容。\n\n'
          '由于相关接口、访问规则及平台策略可能随时发生变化，本应用的搜索、登录、播放、字幕、弹幕、收藏夹、关注列表等功能可能出现失效、受限、延迟或无法使用的情况，开发者无法保证所有功能始终稳定或持续可用。\n\n'
          '本应用不会绕过会员、付费课程、充电专属、私密视频、地区限制或其他访问控制。您只能访问自己依法且依照平台规则有权访问的内容。',
    ),
    _AgreementSection(
      '三、账号登录与安全',
      '本应用的账号登录通过哔哩哔哩官方网页完成。\n\n'
          '如您主动导入 Cookie，请注意：Cookie 可能具有登录凭证效力。请勿向他人泄露 Cookie，也不要使用来源不明、共享或不属于您本人的 Cookie。\n\n'
          '使用第三方客户端可能存在账号会话失效、接口风控或部分功能受限等风险。您应自行判断是否登录，并妥善保护自己的账号安全。',
    ),
    _AgreementSection(
      '四、隐私与本地数据',
      '本应用目前没有开发者自建服务器，我们永远不会将您的哔哩哔哩密码、搜索记录、播放记录、播放进度或时间点笔记上传至开发者服务器。\n\n'
          '搜索记录、观看记录、播放进度、时间点笔记及笔记截图等数据主要保存在您的设备本地。卸载应用、清除应用数据、设备损坏或系统清理可能造成数据丢失，请您自行做好必要备份。\n\n'
          '为获取视频、账号资料、字幕、弹幕及其他内容，本应用需要与哔哩哔哩及相关内容分发服务器进行网络通信。正常网络请求可能向相应服务提供方传递 IP 地址、设备网络信息、Cookie 或其他完成请求所必需的信息，具体处理规则由相应服务提供方的协议和隐私政策决定。',
    ),
    _AgreementSection(
      '五、内容与版权',
      '本应用不拥有、存储或重新授权哔哩哔哩平台上的视频、音频、字幕、弹幕、封面及其他内容。\n\n'
          '您应尊重内容创作者和其他权利人的合法权益，不得利用本应用实施盗版传播、非法下载、破解访问控制、批量抓取、商业搬运、侵犯隐私或其他违反法律法规及平台规则的行为。\n\n'
          '因用户自行复制、导出、分享、传播或使用相关内容所产生的责任，由用户依法承担。',
    ),
    _AgreementSection(
      '六、合理使用',
      '您承诺仅将本应用用于合法、正当的个人用途，并遵守适用的法律法规、哔哩哔哩用户协议、社区规则和内容版权要求。\n\n'
          '请勿利用本应用干扰平台正常运行、攻击网络服务、绕过技术限制、冒用他人账号或从事其他可能损害平台、创作者、开发者及第三方权益的行为。\n\n'
          '未成年人应在监护人的指导下使用本应用，并合理安排观看和学习时间。',
    ),
    _AgreementSection(
      '七、风险说明',
      '本应用按当前实际状态提供。因网络故障、设备兼容性、系统限制、平台接口调整、账号状态变化或其他非开发者能够合理控制的原因，可能出现播放失败、数据异常、功能中断或本地数据丢失。\n\n'
          '在法律允许的范围内，开发者不对上述不可控原因造成的间接损失作出保证或承担超出法律规定范围的责任。本条款不排除或限制依法不得排除或限制的责任。',
    ),
    _AgreementSection(
      '八、协议确认',
      '点击“同意并继续”，表示您已经阅读、理解并同意本协议，并确认知晓本应用是未经哔哩哔哩官方授权的第三方项目及其可能存在的使用风险。\n\n'
          '如您不同意本协议的任何内容，请点击“不同意并退出”，并停止使用本应用。',
    ),
  ];

  final int secondsRemaining;
  final bool accepting;
  final bool exiting;
  final Future<void> Function() onAccept;
  final Future<void> Function() onExit;

  /// 构建一个带清晰标题和可选择正文的协议章节。
  Widget _buildSection(BuildContext context, _AgreementSection section) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            section.title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Text(
            section.body,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(height: 1.65),
          ),
        ],
      ),
    );
  }

  /// 构建可滚动协议正文和固定在底部的退出、同意按钮。
  @override
  Widget build(BuildContext context) {
    final bool canAccept = secondsRemaining == 0 && !accepting && !exiting;
    final String acceptLabel = accepting
        ? '正在保存…'
        : secondsRemaining > 0
        ? '同意并继续（$secondsRemaining 秒）'
        : '同意并继续';
    return Scaffold(
      key: const Key('user-agreement-page'),
      appBar: AppBar(title: const Text('用户须知与使用协议')),
      body: Column(
        children: <Widget>[
          Expanded(
            child: SelectionArea(
              child: ListView(
                key: const Key('user-agreement-scroll-view'),
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                children: <Widget>[
                  Text(
                    '焦点哔哩（FocuBili）用户须知与使用协议',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '更新日期：2026年7月18日\n生效日期：2026年7月18日',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '欢迎使用焦点哔哩（FocuBili）。在继续使用前，请您认真阅读并充分理解以下内容。',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(height: 1.65),
                  ),
                  const SizedBox(height: 24),
                  for (final _AgreementSection section in _sections)
                    _buildSection(context, section),
                ],
              ),
            ),
          ),
          Material(
            elevation: 8,
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('decline-user-agreement'),
                      // 退出按钮函数由启动门禁调用系统退出，不会保存同意状态。
                      onPressed: exiting || accepting ? null : onExit,
                      child: Text(exiting ? '正在退出…' : '不同意并退出'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const Key('accept-user-agreement'),
                      // 同意按钮函数只在十秒倒计时结束后保存本机状态。
                      onPressed: canAccept ? onAccept : null,
                      child: Text(
                        acceptLabel,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
