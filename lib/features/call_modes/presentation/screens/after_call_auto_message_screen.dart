import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicemail/core/extensions/context_extensions.dart';
import 'package:voicemail/core/telephony/telephony_service.dart';
import 'package:voicemail/design_system/components/components.dart';
import 'package:voicemail/design_system/tokens/spacing_tokens.dart';
import 'package:voicemail/features/call_modes/presentation/controllers/modes_controller.dart';

class AfterCallAutoMessageScreen extends ConsumerStatefulWidget {
  const AfterCallAutoMessageScreen({super.key});

  @override
  ConsumerState<AfterCallAutoMessageScreen> createState() => _AfterCallAutoMessageScreenState();
}

class _AfterCallAutoMessageScreenState extends ConsumerState<AfterCallAutoMessageScreen> {
  bool _isEnabled = true;
  String _triggerType = 'ANY'; // ANY, MISSED_ONLY, DECLINED_ONLY, ANSWERED_ONLY
  String _messageTemplate = "Hi, Danish here. Thanks for calling! I can't take your call right now. Please WhatsApp or SMS me. Thanks!";
  bool _onlyUnknown = false;
  int _cooldownHours = 24;
  bool _smsFallback = true;
  String _whatsappMode = 'HEADS_UP_ACTION'; // HEADS_UP_ACTION, DIRECT_LAUNCH

  late final TextEditingController _messageController;
  late final TextEditingController _testNumberController;

  bool _isLoading = true;
  List<Map<String, dynamic>> _logs = [];

  // Testing state
  bool _isTesting = false;
  Map<String, dynamic>? _testResult;

  @override
  void initState() {
    super.initState();
    _messageController = TextEditingController(text: _messageTemplate);
    _testNumberController = TextEditingController();
    _loadSettings();
    _loadLogs();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _testNumberController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _isEnabled = prefs.getBool('after_call_auto_msg_enabled') ?? true;
        _triggerType = prefs.getString('after_call_trigger_type') ?? 'ANY';
        _messageTemplate = prefs.getString('after_call_message_template') ?? _messageTemplate;
        _messageController.text = _messageTemplate;
        _onlyUnknown = prefs.getBool('after_call_only_unknown') ?? false;
        _cooldownHours = prefs.getInt('after_call_cooldown_hours') ?? 24;
        _smsFallback = prefs.getBool('after_call_sms_fallback') ?? true;
        _whatsappMode = prefs.getString('after_call_whatsapp_mode') ?? 'HEADS_UP_ACTION';
        _isLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveSetting<T>(String key, T value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) await prefs.setBool(key, value);
    if (value is String) await prefs.setString(key, value);
    if (value is int) await prefs.setInt(key, value);
  }

  Future<void> _loadLogs() async {
    final logs = await TelephonyService.getAfterCallLogs(limit: 50);
    if (mounted) {
      setState(() => _logs = logs);
    }
  }

  Future<void> _clearLogs() async {
    final confirmed = await AppDialog.showConfirmation(
      context: context,
      title: 'Clear Auto-Message Logs?',
      message: 'This will delete the local history of after-call messages.',
      confirmLabel: 'Clear',
      isDestructive: true,
    );
    if (confirmed == true) {
      await TelephonyService.clearAfterCallLogs();
      await _loadLogs();
      if (mounted) context.showSnackBar('Logs cleared');
    }
  }

  Future<void> _runTestEvaluation() async {
    final number = _testNumberController.text.trim();
    if (number.isEmpty) {
      context.showSnackBar('Please enter a phone number to test');
      return;
    }

    setState(() {
      _isTesting = true;
      _testResult = null;
    });

    final waCheck = await TelephonyService.checkWhatsAppAvailability(number);
    final isMasterActive = ref.read(modesControllerProvider).isAssistantActive;

    // Simulate rule matching
    final isAllowedByMaster = isMasterActive;
    final isAllowedByFeature = _isEnabled;
    final hasWhatsApp = waCheck['isAvailable'] == true;
    final normalized = waCheck['normalizedNumber'] ?? number;

    String simulatedAction;
    if (!isAllowedByMaster) {
      simulatedAction = 'BLOCKED: Assistant Master Switch is OFF. No message will be sent.';
    } else if (!isAllowedByFeature) {
      simulatedAction = 'BLOCKED: Auto-Message After Call feature is currently toggled OFF.';
    } else if (hasWhatsApp) {
      simulatedAction = 'SUCCESS: WhatsApp found (${waCheck['detail']}). Pre-set message will open in personal WhatsApp chat ready to send in 1 tap.';
    } else if (_smsFallback) {
      simulatedAction = 'FALLBACK: WhatsApp not found (${waCheck['detail']}). Automatically dispatches pre-set message via SMS.';
    } else {
      simulatedAction = 'SKIPPED: Caller does not have WhatsApp and SMS fallback is disabled.';
    }

    if (mounted) {
      setState(() {
        _isTesting = false;
        _testResult = {
          'normalizedNumber': normalized,
          'hasWhatsApp': hasWhatsApp,
          'waDetail': waCheck['detail'],
          'action': simulatedAction,
          'masterActive': isMasterActive,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final modesState = ref.watch(modesControllerProvider);

    return AppScaffold(
      appBar: AppAppBar(
        title: 'Auto-Message After Call',
        subtitle: 'Personal WhatsApp & SMS Auto-Replies',
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh Logs',
            onPressed: _loadLogs,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear Logs',
            onPressed: _logs.isEmpty ? null : _clearLogs,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: AppSpacing.padding16,
              children: [
                // 1. Master Switch Warning if Off
                if (!modesState.isAssistantActive) ...[
                  const AppStatusBanner(
                    type: AppBannerType.warning,
                    title: 'Assistant Paused (Master Switch OFF)',
                    message:
                        'The main assistant is currently paused. Auto-messaging after calls will stay silent until the assistant is turned back ON.',
                  ),
                  AppSpacing.vSpace16,
                ],

                // 2. Feature Master Toggle
                AppCard(
                  variant: AppCardVariant.filled,
                  color: _isEnabled
                      ? colorScheme.primaryContainer.withValues(alpha: 0.35)
                      : colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                  child: AppSwitchRow(
                    leading: Icon(
                      Icons.mark_chat_unread_rounded,
                      color: _isEnabled ? colorScheme.primary : colorScheme.onSurfaceVariant,
                    ),
                    title: 'Auto-Message After Call',
                    subtitle: 'Dispatch personal WhatsApp or SMS text when calls end or are missed',
                    value: _isEnabled,
                    onChanged: (val) {
                      setState(() => _isEnabled = val);
                      _saveSetting('after_call_auto_msg_enabled', val);
                    },
                  ),
                ),
                AppSpacing.vSpace16,

                // 3. Trigger Type Selector
                Text(
                  'TRIGGER CALL TYPES',
                  style: context.textTheme.labelMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                AppSpacing.vSpace8,
                AppCard(
                  variant: AppCardVariant.outlined,
                  child: Column(
                    children: [
                      _buildTriggerRadio('ANY', 'All Calls', 'Trigger for missed, answered, or rejected calls', Icons.call_rounded),
                      const Divider(),
                      _buildTriggerRadio('MISSED_ONLY', 'Missed Calls Only', 'Trigger only when caller hangs up before answering', Icons.phone_missed_rounded),
                      const Divider(),
                      _buildTriggerRadio('DECLINED_ONLY', 'Declined Calls Only', 'Trigger only when you or the assistant declines the call', Icons.call_end_rounded),
                      const Divider(),
                      _buildTriggerRadio('ANSWERED_ONLY', 'Answered Calls Only', 'Follow up after an answered conversation finishes', Icons.phone_callback_rounded),
                    ],
                  ),
                ),
                AppSpacing.vSpace20,

                // 4. WhatsApp & SMS Delivery Options
                Text(
                  'DELIVERY CHANNELS & FALLBACK',
                  style: context.textTheme.labelMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                AppSpacing.vSpace8,
                AppCard(
                  variant: AppCardVariant.outlined,
                  child: Column(
                    children: [
                      const AppSwitchRow(
                        leading: Icon(Icons.chat_rounded, color: Colors.green),
                        title: 'Personal WhatsApp First',
                        subtitle: 'Official, safe click-to-chat intent without risk of account ban',
                        value: true,
                        onChanged: null, // Always preferred
                      ),
                      const Divider(),
                      AppSwitchRow(
                        leading: const Icon(Icons.sms_outlined, color: Colors.blue),
                        title: 'SMS Fallback',
                        subtitle: 'If caller has no WhatsApp account, automatically send SMS',
                        value: _smsFallback,
                        onChanged: (val) {
                          setState(() => _smsFallback = val);
                          _saveSetting('after_call_sms_fallback', val);
                        },
                      ),
                      const Divider(),
                      AppListTile(
                        leading: const Icon(Icons.notifications_active_outlined),
                        title: const Text('WhatsApp Dispatch Mode'),
                        subtitle: Text(
                          _whatsappMode == 'HEADS_UP_ACTION'
                              ? 'Heads-up alert with 1-tap Send button'
                              : 'Directly launch WhatsApp chat',
                        ),
                        trailing: const Icon(Icons.arrow_drop_down),
                        onTap: () {
                          setState(() {
                            _whatsappMode = _whatsappMode == 'HEADS_UP_ACTION' ? 'DIRECT_LAUNCH' : 'HEADS_UP_ACTION';
                            _saveSetting('after_call_whatsapp_mode', _whatsappMode);
                          });
                        },
                      ),
                    ],
                  ),
                ),
                AppSpacing.vSpace20,

                // 5. Anti-Spam & Audience Filtering
                Text(
                  'ANTI-SPAM & AUDIENCE FILTERS',
                  style: context.textTheme.labelMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                AppSpacing.vSpace8,
                AppCard(
                  variant: AppCardVariant.outlined,
                  child: Column(
                    children: [
                      AppSwitchRow(
                        leading: const Icon(Icons.person_outline),
                        title: 'Only Unknown Numbers',
                        subtitle: 'Skip saved phonebook contacts and only auto-message new callers',
                        value: _onlyUnknown,
                        onChanged: (val) {
                          setState(() => _onlyUnknown = val);
                          _saveSetting('after_call_only_unknown', val);
                        },
                      ),
                      const Divider(),
                      AppListTile(
                        leading: const Icon(Icons.timer_outlined),
                        title: const Text('Message Cooldown'),
                        subtitle: Text('Never send more than once per $_cooldownHours hours to the same caller'),
                        trailing: DropdownButton<int>(
                          value: _cooldownHours,
                          underline: const SizedBox(),
                          items: const [
                            DropdownMenuItem(value: 1, child: Text('1 hour')),
                            DropdownMenuItem(value: 6, child: Text('6 hours')),
                            DropdownMenuItem(value: 12, child: Text('12 hours')),
                            DropdownMenuItem(value: 24, child: Text('24 hours')),
                            DropdownMenuItem(value: 48, child: Text('48 hours')),
                          ],
                          onChanged: (val) {
                            if (val != null) {
                              setState(() => _cooldownHours = val);
                              _saveSetting('after_call_cooldown_hours', val);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                AppSpacing.vSpace20,

                // 6. Message Template
                Text(
                  'MESSAGE TEMPLATE',
                  style: context.textTheme.labelMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                AppSpacing.vSpace8,
                TextField(
                  controller: _messageController,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: 'Pre-set Message',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  ),
                  onChanged: (val) {
                    _messageTemplate = val;
                    _saveSetting('after_call_message_template', val);
                  },
                ),
                AppSpacing.vSpace20,

                // 7. Interactive Test Tool
                Text(
                  'TEST AUTO-MESSAGE PIPELINE',
                  style: context.textTheme.labelMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                AppSpacing.vSpace8,
                AppCard(
                  variant: AppCardVariant.outlined,
                  child: Column(
                    children: [
                      TextField(
                        controller: _testNumberController,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          labelText: 'Test Phone Number',
                          hintText: 'e.g. +919845012345 or 9845012345',
                          prefixIcon: const Icon(Icons.phone_android),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.contacts_outlined),
                            tooltip: 'Pick contact',
                            onPressed: () async {
                              final perm = await FlutterContacts.requestPermission(readonly: true);
                              if (perm) {
                                final contact = await FlutterContacts.openExternalPick();
                                if (contact != null && contact.phones.isNotEmpty) {
                                  _testNumberController.text = contact.phones.first.number;
                                }
                              }
                            },
                          ),
                        ),
                      ),
                      AppSpacing.vSpace12,
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          icon: _isTesting
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.play_arrow_rounded),
                          label: Text(_isTesting ? 'Verifying WhatsApp & Rules...' : 'Test Auto-Message'),
                          onPressed: _isTesting ? null : _runTestEvaluation,
                        ),
                      ),
                      if (_testResult != null) ...[
                        AppSpacing.vSpace12,
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: colorScheme.primary),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    _testResult!['hasWhatsApp'] == true ? Icons.check_circle : Icons.info_outline,
                                    color: _testResult!['hasWhatsApp'] == true ? Colors.green : Colors.orange,
                                    size: 18,
                                  ),
                                  AppSpacing.hSpace8,
                                  Expanded(
                                    child: Text(
                                      'E.164: ${_testResult!['normalizedNumber']} • ${_testResult!['waDetail']}',
                                      style: context.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                              AppSpacing.vSpace8,
                              Text(
                                (_testResult!['action'] ?? '').toString(),
                                style: context.textTheme.bodySmall?.copyWith(height: 1.35),
                              ),
                              AppSpacing.vSpace8,
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  icon: const Icon(Icons.open_in_new, size: 16),
                                  label: const Text('Open in WhatsApp Now'),
                                  onPressed: () {
                                    final targetNum = (_testResult!['normalizedNumber'] ?? '').toString();
                                    TelephonyService.openWhatsAppChat(
                                      targetNum,
                                      _messageTemplate,
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                AppSpacing.vSpace20,

                // 8. Live Real Event Logs
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'EVENT AUDIT LOG (${_logs.length})',
                      style: context.textTheme.labelMedium?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.0,
                      ),
                    ),
                    if (_logs.isNotEmpty)
                      TextButton(
                        onPressed: _clearLogs,
                        child: const Text('Clear All', style: TextStyle(color: Colors.red)),
                      ),
                  ],
                ),
                AppSpacing.vSpace8,

                if (_logs.isEmpty)
                  const AppEmptyState(
                    icon: Icons.history_rounded,
                    title: 'No Auto-Messages Recorded Yet',
                    description:
                        'When someone calls, misses, or finishes a call with you, the event, WhatsApp account check, and delivery result will appear here in real-time.',
                  )
                else
                  ..._logs.map((log) => _buildLogCard(log)),
                AppSpacing.vSpace24,
              ],
            ),
    );
  }

  Widget _buildTriggerRadio(String value, String title, String subtitle, IconData icon) {
    final isSelected = _triggerType == value;
    final colorScheme = context.colorScheme;
    return InkWell(
      onTap: () {
        setState(() => _triggerType = value);
        _saveSetting('after_call_trigger_type', value);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: isSelected ? colorScheme.primary : colorScheme.onSurfaceVariant),
            AppSpacing.hSpace12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: context.textTheme.titleSmall?.copyWith(
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                      color: isSelected ? colorScheme.primary : colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: context.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle_rounded, color: colorScheme.primary, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildLogCard(Map<String, dynamic> log) {
    final colorScheme = context.colorScheme;
    final number = log['caller_number']?.toString() ?? 'Unknown';
    final name = log['caller_name']?.toString() ?? '';
    final callType = log['call_type']?.toString() ?? 'CALL';
    final timestamp = log['timestamp'] as int? ?? 0;
    final hasWa = log['whatsapp_found'] == true;
    final method = log['dispatch_method']?.toString() ?? 'NONE';
    final status = log['status']?.toString() ?? '';
    final reason = log['reason']?.toString() ?? '';

    final dateStr = timestamp > 0
        ? DateTime.fromMillisecondsSinceEpoch(timestamp).toString().substring(0, 19).replaceAll('T', ' ')
        : '';

    Color badgeColor;
    if (status.contains('SENT')) {
      badgeColor = Colors.green;
    } else if (status.contains('BLOCKED')) {
      badgeColor = Colors.orange;
    } else {
      badgeColor = Colors.blueGrey;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: AppCard(
        variant: AppCardVariant.outlined,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Icon(
                        hasWa ? Icons.chat_rounded : Icons.sms_outlined,
                        size: 16,
                        color: hasWa ? Colors.green : Colors.blue,
                      ),
                      AppSpacing.hSpace8,
                      Expanded(
                        child: Text(
                          name.isNotEmpty ? '$name ($number)' : number,
                          style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    callType,
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: badgeColor),
                  ),
                ),
              ],
            ),
            AppSpacing.vSpace6,
            Text(
              reason,
              style: context.textTheme.bodySmall?.copyWith(color: colorScheme.onSurface),
            ),
            AppSpacing.vSpace6,
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Method: $method • Status: $status',
                  style: context.textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
                Text(
                  dateStr,
                  style: context.textTheme.labelSmall?.copyWith(color: colorScheme.outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
