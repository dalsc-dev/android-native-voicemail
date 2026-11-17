import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voicemail/core/constants/app_constants.dart';
import 'package:voicemail/core/extensions/context_extensions.dart';
import 'package:voicemail/core/telephony/telephony_service.dart';
import 'package:voicemail/design_system/components/components.dart';
import 'package:voicemail/design_system/tokens/spacing_tokens.dart';
import 'package:voicemail/features/call_modes/domain/auto_reply_rules.dart';
import 'package:voicemail/features/call_modes/presentation/controllers/auto_messaging_controller.dart';

class AutoMessagingScreen extends ConsumerStatefulWidget {
  const AutoMessagingScreen({super.key});

  @override
  ConsumerState<AutoMessagingScreen> createState() => _AutoMessagingScreenState();
}

class _AutoMessagingScreenState extends ConsumerState<AutoMessagingScreen> {
  late final TextEditingController _messageController;
  late final TextEditingController _waNumberController;
  late final TextEditingController _testNumberController;
  bool _isTesting = false;
  String? _testResultTitle;
  String? _testResultMessage;
  bool _testSuccess = false;

  @override
  void initState() {
    super.initState();
    final state = ref.read(autoMessagingControllerProvider);
    _messageController = TextEditingController(text: state.customMessage);
    _waNumberController = TextEditingController(text: state.whatsAppNumber);
    _testNumberController = TextEditingController();
  }

  @override
  void dispose() {
    _messageController.disposeDisposeSafe();
    _waNumberController.disposeDisposeSafe();
    _testNumberController.disposeDisposeSafe();
    super.dispose();
  }

  Future<void> _performTestDispatch() async {
    final rawNumber = _testNumberController.text.trim();
    if (rawNumber.isEmpty) {
      context.showSnackBar('Please enter a phone number to test');
      return;
    }

    setState(() {
      _isTesting = true;
      _testResultTitle = null;
      _testResultMessage = null;
    });

    final state = ref.read(autoMessagingControllerProvider);
    final cleanDigits = rawNumber.replaceAll(RegExp(r'[^0-9]'), '');
    final normNumber = cleanDigits.length >= 10 ? cleanDigits.substring(cleanDigits.length - 10) : cleanDigits;

    bool shouldSend = false;
    String conditionExplanation = '';

    switch (state.targetMode) {
      case AutoMsgTargetMode.all:
        shouldSend = true;
        conditionExplanation = 'Option 1 (All Callers) is active. Auto-replies are allowed for all numbers.';
        break;
      case AutoMsgTargetMode.selectedOnly:
        final isWhitelisted = state.selectedContacts.any((c) {
          final cClean = c.cleanNumber;
          return cClean == normNumber || cClean.endsWith(normNumber) || normNumber.endsWith(cClean);
        });
        if (isWhitelisted) {
          shouldSend = true;
          conditionExplanation = 'Option 2 (Selected Numbers Only): $rawNumber matches your Whitelist. Auto-message approved!';
        } else {
          shouldSend = false;
          conditionExplanation = 'Option 2 (Selected Numbers Only): $rawNumber is NOT in your Whitelist. Message prevented as configured.';
        }
        break;
      case AutoMsgTargetMode.unsavedOnly:
        final isWhitelisted = state.selectedContacts.any((c) => c.cleanNumber == normNumber);
        shouldSend = !isWhitelisted;
        conditionExplanation = shouldSend
            ? 'Option 3 (Unsaved Only): Number is not in your saved list. Auto-message approved.'
            : 'Option 3 (Unsaved Only): Number matches a known contact. Auto-message withheld.';
        break;
      case AutoMsgTargetMode.excludeSelected:
        final isBlacklisted = state.selectedContacts.any((c) {
          final cClean = c.cleanNumber;
          return cClean == normNumber || cClean.endsWith(normNumber) || normNumber.endsWith(cClean);
        });
        if (isBlacklisted) {
          shouldSend = false;
          conditionExplanation = 'Option 4 (Exclude Selected): $rawNumber is in your Blacklist. Auto-message blocked.';
        } else {
          shouldSend = true;
          conditionExplanation = 'Option 4 (Exclude Selected): $rawNumber is not blacklisted. Auto-message approved.';
        }
        break;
    }

    if (shouldSend) {
      final res = await TelephonyService.sendSms(
        recipient: rawNumber,
        message: state.previewMessage,
      );
      final isSent = res['success'] == true;
      if (mounted) {
        setState(() {
          _isTesting = false;
          _testSuccess = isSent;
          _testResultTitle = isSent ? 'Message Delivered' : 'Delivery Failed';
          _testResultMessage = isSent
              ? '$conditionExplanation\n\nResult: SMS successfully dispatched to $rawNumber.'
              : '$conditionExplanation\n\nResult: SMS dispatch failed (${res['error'] ?? 'Permission or Carrier issue'}). Recorded in diagnostics.';
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _isTesting = false;
          _testSuccess = true;
          _testResultTitle = 'Rule Enforced Correctly';
          _testResultMessage = conditionExplanation;
        });
      }
    }
  }

  Future<void> _pickContactFromPhone() async {
    try {
      final hasPermission = await FlutterContacts.requestPermission(readonly: true);
      if (!hasPermission) {
        if (mounted) context.showSnackBar('Contacts permission is required to select numbers.');
        return;
      }

      final contact = await FlutterContacts.openExternalPick();
      if (contact != null && contact.phones.isNotEmpty) {
        final phone = contact.phones.first.number;
        final name = contact.displayName.isNotEmpty ? contact.displayName : 'Contact';
        await ref.read(autoMessagingControllerProvider.notifier).addContact(
              AutoReplyContact(name: name, number: phone),
            );
        if (mounted) context.showSnackBar('Added $name ($phone)');
      }
    } catch (e) {
      if (mounted) context.showSnackBar('Could not pick contact: $e');
    }
  }

  Future<void> _showAddManualDialog() async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Phone Number'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Contact Name (Optional)',
                hintText: 'e.g. John Doe / Colleague',
                prefixIcon: Icon(Icons.person_outline),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            AppSpacing.vSpace12,
            TextField(
              controller: phoneController,
              decoration: const InputDecoration(
                labelText: 'Phone Number',
                hintText: 'e.g. 9845012345 or +91...',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
              keyboardType: TextInputType.phone,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final rawNumber = phoneController.text.trim();
              if (rawNumber.isEmpty) return;
              final name = nameController.text.trim().isEmpty ? 'Custom Number' : nameController.text.trim();
              ref.read(autoMessagingControllerProvider.notifier).addContact(
                    AutoReplyContact(name: name, number: rawNumber),
                  );
              Navigator.pop(ctx);
              context.showSnackBar('Added $name ($rawNumber)');
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(autoMessagingControllerProvider);
    final controller = ref.read(autoMessagingControllerProvider.notifier);
    final colorScheme = context.colorScheme;

    // Sync message controller if changed via preset
    if (_messageController.text != state.customMessage) {
      _messageController.text = state.customMessage;
      _messageController.selection = TextSelection.collapsed(offset: state.customMessage.length);
    }

    return AppScaffold(
      appBar: const AppAppBar(
        title: 'Smart Auto-Messaging',
        subtitle: 'Audience Targeting & Dynamic SMS',
      ),
      body: ListView(
        padding: AppSpacing.padding16,
        children: [
          // 1. Audience Target Selector
          Text(
            'WHO RECEIVES AUTO-MESSAGES?',
            style: context.textTheme.labelMedium?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          AppSpacing.vSpace8,
          Text(
            'Choose exactly who receives automated SMS replies when you are in class, driving, or decline calls.',
            style: context.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          AppSpacing.vSpace12,

          ...AutoMsgTargetMode.values.map((mode) {
            final isSelected = state.targetMode == mode;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: AppCard(
                variant: isSelected ? AppCardVariant.filled : AppCardVariant.outlined,
                color: isSelected ? colorScheme.primaryContainer.withValues(alpha: 0.35) : null,
                borderSide: isSelected
                    ? BorderSide(color: colorScheme.primary, width: 1.8)
                    : BorderSide(color: colorScheme.outlineVariant),
                onTap: () => controller.setTargetMode(mode),
                child: Row(
                  children: [
                    // ignore: deprecated_member_use
                    Radio<AutoMsgTargetMode>(
                      value: mode,
                      // ignore: deprecated_member_use
                      groupValue: state.targetMode,
                      // ignore: deprecated_member_use
                      onChanged: (val) {
                        if (val != null) controller.setTargetMode(val);
                      },
                    ),
                    AppSpacing.hSpace8,
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(mode.icon, size: 18, color: isSelected ? colorScheme.primary : colorScheme.onSurface),
                              AppSpacing.hSpace8,
                              Text(
                                mode.title,
                                style: context.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: isSelected ? colorScheme.primary : colorScheme.onSurface,
                                ),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isSelected ? colorScheme.primary : colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  mode.badgeText,
                                  style: context.textTheme.labelSmall?.copyWith(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: isSelected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          AppSpacing.vSpace4,
                          Text(
                            mode.subtitle,
                            style: context.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          AppSpacing.vSpace16,

          // 2. Selected Numbers Management Section
          if (state.targetMode == AutoMsgTargetMode.selectedOnly ||
              state.targetMode == AutoMsgTargetMode.excludeSelected) ...[
            Text(
              state.targetMode == AutoMsgTargetMode.selectedOnly
                  ? 'WHITELIST NUMBERS (${state.selectedContacts.length})'
                  : 'BLACKLIST NUMBERS (${state.selectedContacts.length})',
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          icon: const Icon(Icons.contacts_rounded, size: 18),
                          label: const Text('From Contacts'),
                          onPressed: _pickContactFromPhone,
                        ),
                      ),
                      AppSpacing.hSpace8,
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Add Manually'),
                          onPressed: _showAddManualDialog,
                        ),
                      ),
                    ],
                  ),
                  if (state.selectedContacts.isNotEmpty) ...[
                    AppSpacing.vSpace12,
                    const Divider(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${state.selectedContacts.length} numbers configured',
                          style: context.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        TextButton(
                          onPressed: () => controller.clearAllContacts(),
                          child: const Text('Clear All', style: TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                    AppSpacing.vSpace4,
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: state.selectedContacts.map((c) {
                        return Chip(
                          avatar: CircleAvatar(
                            backgroundColor: colorScheme.primaryContainer,
                            child: Text(
                              c.name.isNotEmpty ? c.name[0].toUpperCase() : '#',
                              style: TextStyle(fontSize: 11, color: colorScheme.onPrimaryContainer),
                            ),
                          ),
                          label: Text('${c.name} (${c.number})'),
                          deleteIcon: const Icon(Icons.close_rounded, size: 16),
                          onDeleted: () => controller.removeContact(c),
                        );
                      }).toList(),
                    ),
                  ] else ...[
                    AppSpacing.vSpace12,
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline, size: 20, color: colorScheme.outline),
                          AppSpacing.hSpace12,
                          Expanded(
                            child: Text(
                              state.targetMode == AutoMsgTargetMode.selectedOnly
                                  ? 'No numbers selected yet. Tap above to pick contacts who should receive auto-replies.'
                                  : 'No numbers excluded yet. Tap above to add numbers to exclude from auto-replies.',
                              style: context.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
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
          ],

          // 3. Innovative Smart Enhancements
          Text(
            'INNOVATIVE SMART ENHANCEMENTS',
            style: context.textTheme.labelMedium?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          AppSpacing.vSpace12,

          AppCard(
            variant: AppCardVariant.outlined,
            child: Column(
              children: [
                // Enhancement 1: Click-to-WhatsApp Direct Link
                AppSwitchRow(
                  leading: const Icon(Icons.chat_bubble_outline_rounded, color: Colors.green),
                  title: 'Click-to-WhatsApp Link',
                  subtitle: 'Appends 1-tap WhatsApp link so callers can message or send free voice notes',
                  value: state.includeWhatsAppLink,
                  onChanged: (val) => controller.toggleIncludeWhatsApp(val),
                ),
                if (state.includeWhatsAppLink) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: TextField(
                      controller: _waNumberController,
                      decoration: const InputDecoration(
                        labelText: 'Your Messaging / WhatsApp Number',
                        hintText: 'Include country code (e.g. +1..., +44..., +91...)',
                        prefixIcon: Icon(Icons.phone_iphone_rounded, color: Colors.green),
                        isDense: true,
                      ),
                      keyboardType: TextInputType.phone,
                      onChanged: (val) => controller.setWhatsAppNumber(val.trim()),
                    ),
                  ),
                ],
                const Divider(),

                // Enhancement 2: Emergency 2-Call Breakthrough
                AppSwitchRow(
                  leading: const Icon(Icons.emergency_outlined, color: Colors.red),
                  title: 'Emergency 2-Call Breakthrough',
                  subtitle: 'If someone calls twice within 3 minutes, bypass auto-decline and ring phone out loud',
                  value: state.emergencyBreakthrough,
                  onChanged: (val) => controller.toggleEmergencyBreakthrough(val),
                ),
              ],
            ),
          ),
          AppSpacing.vSpace20,

          // 4. Message Presets & Composer
          Text(
            'AUTO-REPLY MESSAGE COMPOSER',
            style: context.textTheme.labelMedium?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          AppSpacing.vSpace8,
          Text(
            'Select a quick preset or craft your custom response:',
            style: context.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          AppSpacing.vSpace8,

          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: AutoReplyPreset.presets.map((preset) {
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: ActionChip(
                    avatar: Icon(preset.icon, size: 16),
                    label: Text(preset.title),
                    onPressed: () {
                      _messageController.text = preset.template;
                      controller.setCustomMessage(preset.template);
                    },
                  ),
                );
              }).toList(),
            ),
          ),
          AppSpacing.vSpace12,

          TextField(
            controller: _messageController,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: 'Write your auto-reply text here...',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            ),
            onChanged: (val) => controller.setCustomMessage(val),
          ),
          AppSpacing.vSpace20,

          // 5. Live SMS Preview Bubble
          Text(
            'CALLER SMS PREVIEW',
            style: context.textTheme.labelMedium?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          AppSpacing.vSpace8,

          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.sms_outlined, size: 16, color: colorScheme.primary),
                    AppSpacing.hSpace8,
                    Text(
                      'SMS sent to caller upon call decline',
                      style: context.textTheme.labelSmall?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                AppSpacing.vSpace12,
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(16),
                      topRight: Radius.circular(16),
                      bottomRight: Radius.circular(16),
                      bottomLeft: Radius.circular(4),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    state.previewMessage,
                    style: context.textTheme.bodyMedium?.copyWith(height: 1.4),
                  ),
                ),
                AppSpacing.vSpace8,
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${state.previewMessage.length} characters',
                    style: context.textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          // 6. Test Auto-Reply Delivery & Rules Verification
          Text(
            'TEST AUTO-REPLY DELIVERY',
            style: context.textTheme.labelMedium?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          AppSpacing.vSpace8,
          Text(
            'Verify your active option rule (Option 2 Whitelist, Blacklist, or All) and confirm real-time SMS delivery.',
            style: context.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          AppSpacing.vSpace12,

          AppCard(
            variant: AppCardVariant.outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _testNumberController,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: 'Test Phone Number',
                    hintText: 'e.g. +919845012345 or 9845012345',
                    prefixIcon: const Icon(Icons.phone_android_rounded),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.contacts_outlined),
                      tooltip: 'Select from contacts',
                      onPressed: () async {
                        try {
                          final hasPerm = await FlutterContacts.requestPermission(readonly: true);
                          if (hasPerm) {
                            final contact = await FlutterContacts.openExternalPick();
                            if (contact != null && contact.phones.isNotEmpty) {
                              _testNumberController.text = contact.phones.first.number;
                            }
                          }
                        } catch (_) {}
                      },
                    ),
                  ),
                ),
                AppSpacing.vSpace12,
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: _isTesting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.send_rounded, size: 18),
                    label: Text(_isTesting ? 'Evaluating & Delivering...' : 'Test Message Delivery'),
                    onPressed: _isTesting ? null : _performTestDispatch,
                  ),
                ),
                if (_testResultTitle != null) ...[
                  AppSpacing.vSpace12,
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _testSuccess
                          ? colorScheme.primaryContainer.withValues(alpha: 0.3)
                          : colorScheme.errorContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _testSuccess ? colorScheme.primary : colorScheme.error,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _testSuccess ? Icons.check_circle_outline : Icons.error_outline,
                              size: 18,
                              color: _testSuccess ? colorScheme.primary : colorScheme.error,
                            ),
                            AppSpacing.hSpace8,
                            Text(
                              _testResultTitle!,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: _testSuccess ? colorScheme.primary : colorScheme.error,
                              ),
                            ),
                          ],
                        ),
                        AppSpacing.vSpace6,
                        Text(
                          _testResultMessage ?? '',
                          style: context.textTheme.bodySmall?.copyWith(height: 1.4),
                        ),
                        AppSpacing.vSpace8,
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            icon: const Icon(Icons.history_rounded, size: 16),
                            label: const Text('View in Call Diagnostics'),
                            onPressed: () => context.push(AppConstants.routeDiagnostics),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          AppSpacing.vSpace24,
        ],
      ),
    );
  }
}

extension on TextEditingController {
  void disposeDisposeSafe() {
    try {
      dispose();
    } catch (_) {}
  }
}
