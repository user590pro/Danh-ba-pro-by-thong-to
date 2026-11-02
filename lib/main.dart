import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'utils/vietnamese_matcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ContactFinderApp());
}

class ContactFinderApp extends StatelessWidget {
  const ContactFinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Danh Bạ Pro by Thông Tô',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E88E5),
          brightness: Brightness.light,
          primary: const Color(0xFF1565C0),
          secondary: const Color(0xFFF59E0B),
        ),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
      ),
      home: const MainHomeScreen(),
    );
  }
}

class ScoredContact {
  final PreparedContact contact;
  final SearchMatchResult matchResult;

  const ScoredContact({
    required this.contact,
    required this.matchResult,
  });
}

class CallLogItem {
  final String id;
  final String number;
  final String? name;
  final int type; // 1: Incoming, 2: Outgoing, 3: Missed, 5: Rejected
  final int date; // timestamp in millis
  final int duration; // in seconds

  CallLogItem({
    required this.id,
    required this.number,
    this.name,
    required this.type,
    required this.date,
    required this.duration,
  });

  factory CallLogItem.fromMap(Map<dynamic, dynamic> map) {
    return CallLogItem(
      id: map['id']?.toString() ?? '',
      number: map['number']?.toString() ?? '',
      name: map['name']?.toString(),
      type: (map['type'] as num?)?.toInt() ?? 1,
      date: (map['date'] as num?)?.toInt() ?? 0,
      duration: (map['duration'] as num?)?.toInt() ?? 0,
    );
  }
}

class GroupedCallLog {
  final String normalizedNumber;
  final String rawNumber;
  final String? name;
  final List<CallLogItem> calls;

  GroupedCallLog({
    required this.normalizedNumber,
    required this.rawNumber,
    this.name,
    required this.calls,
  });

  CallLogItem get latestCall => calls.first;
  int get count => calls.length;
}

class MainHomeScreen extends StatefulWidget {
  const MainHomeScreen({super.key});

  @override
  State<MainHomeScreen> createState() => _MainHomeScreenState();
}

class _MainHomeScreenState extends State<MainHomeScreen> with WidgetsBindingObserver {
  static const MethodChannel _dialerChannel = MethodChannel('com.antigravity.contactfinder/dialer');

  int _currentTabIndex = 0; // 0: Gần đây, 1: Bàn phím, 2: Danh bạ
  List<PreparedContact> _allContacts = [];
  bool _isLoadingContacts = true;
  bool _permissionDenied = false;
  bool _isDefaultDialer = true;

  // Call Logs state
  List<CallLogItem> _callLogs = [];
  bool _isLoadingCallLogs = false;
  int _callLogFilter = 0; // 0: Tất cả, 1: Cuộc gọi nhỡ

  // Dialpad state
  final TextEditingController _dialController = TextEditingController();
  List<ScoredContact> _dialMatchedContacts = [];

  // Contacts Search state
  final TextEditingController _searchController = TextEditingController();
  List<ScoredContact> _filteredContacts = [];
  String _currentQuery = '';
  Timer? _debounceTimer;

  // Cached static styles
  static const _nameBaseStyle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.bold,
    color: Color(0xFF0F172A),
  );

  static const _nameHighlightStyle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w900,
    color: Color(0xFF78350F),
    backgroundColor: Color(0xFFFACC15),
  );

  static const _phoneBaseStyle = TextStyle(
    fontSize: 14,
    color: Color(0xFF475569),
    fontWeight: FontWeight.normal,
  );

  static const _phoneHighlightStyle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w900,
    color: Color(0xFF78350F),
    backgroundColor: Color(0xFFFACC15),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadContacts();
    _loadCallLogs();
    _checkDefaultDialer();
    _searchController.addListener(_onSearchChanged);
    _dialController.addListener(_onDialChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounceTimer?.cancel();
    _searchController.dispose();
    _dialController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkDefaultDialer();
      _loadCallLogs();
    }
  }

  Future<void> _checkDefaultDialer() async {
    try {
      final isDefault = await _dialerChannel.invokeMethod<bool>('isDefaultDialer');
      if (mounted && isDefault != null) {
        setState(() {
          _isDefaultDialer = isDefault;
        });
      }
    } catch (_) {}
  }

  Future<void> _requestDefaultDialer() async {
    try {
      await _dialerChannel.invokeMethod('requestDefaultDialer');
      Future.delayed(const Duration(seconds: 1), _checkDefaultDialer);
    } catch (_) {}
  }

  Future<void> _loadCallLogs() async {
    setState(() {
      _isLoadingCallLogs = true;
    });

    try {
      final List<dynamic>? rawLogs = await _dialerChannel.invokeMethod('getCallLogs');
      if (rawLogs != null) {
        final logs = rawLogs
            .map((e) => CallLogItem.fromMap(e as Map<dynamic, dynamic>))
            .toList();
        if (mounted) {
          setState(() {
            _callLogs = logs;
            _isLoadingCallLogs = false;
          });
        }
      } else {
        if (mounted) setState(() => _isLoadingCallLogs = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingCallLogs = false);
    }
  }

  Future<void> _loadContacts() async {
    setState(() {
      _isLoadingContacts = true;
      _permissionDenied = false;
    });

    try {
      bool hasPermission = await FlutterContacts.permissions.has(PermissionType.read);
      if (!hasPermission) {
        final status = await FlutterContacts.permissions.request(PermissionType.read);
        hasPermission = (status == PermissionStatus.granted || status == PermissionStatus.limited);
      }

      if (!hasPermission) {
        setState(() {
          _isLoadingContacts = false;
          _permissionDenied = true;
        });
        return;
      }

      final contacts = await FlutterContacts.getAll(
        properties: {
          ContactProperty.name,
          ContactProperty.phone,
        },
      );

      final items = <PreparedContact>[];
      for (final c in contacts) {
        final phones = <String>[];
        for (final p in c.phones) {
          final trimmed = p.number.trim();
          if (trimmed.isNotEmpty) phones.add(trimmed);
        }

        final name = (c.displayName != null && c.displayName!.trim().isNotEmpty)
            ? c.displayName!.trim()
            : 'Không có tên';

        items.add(PreparedContact(
          id: c.id ?? '',
          displayName: name,
          rawPhones: phones,
        ));
      }

      setState(() {
        _allContacts = items;
        _isLoadingContacts = false;
      });
      _filterContacts(_searchController.text);
      _updateDialpadMatches();
    } catch (e) {
      setState(() {
        _isLoadingContacts = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi tải danh bạ: $e')),
        );
      }
    }
  }

  void _onSearchChanged() {
    final query = _searchController.text;
    if (query != _currentQuery) {
      _currentQuery = query;
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 80), () {
        _filterContacts(query);
      });
    }
  }

  void _onDialChanged() {
    _updateDialpadMatches();
  }

  void _filterContacts(String rawQuery) {
    final query = rawQuery.trim();
    if (query.isEmpty) {
      setState(() {
        _filteredContacts = _allContacts
            .map((c) => ScoredContact(
                  contact: c,
                  matchResult: const SearchMatchResult(isMatched: true, score: 0),
                ))
            .toList();
      });
      return;
    }

    final preparedQuery = PreparedQuery(query);
    final matched = <ScoredContact>[];

    for (int i = 0; i < _allContacts.length; i++) {
      final c = _allContacts[i];
      final res = VietnameseMatcher.matchPreparedContact(
        contact: c,
        query: preparedQuery,
      );

      if (res.isMatched) {
        matched.add(ScoredContact(
          contact: c,
          matchResult: res,
        ));
      }
    }

    matched.sort((a, b) => b.matchResult.score.compareTo(a.matchResult.score));

    setState(() {
      _filteredContacts = matched;
    });
  }

  void _updateDialpadMatches() {
    final rawNumber = _dialController.text;
    if (rawNumber.isEmpty) {
      setState(() {
        _dialMatchedContacts = [];
      });
      return;
    }

    final queryDigits = VietnameseMatcher.extractDigits(rawNumber);
    if (queryDigits.isEmpty) {
      setState(() {
        _dialMatchedContacts = [];
      });
      return;
    }

    final preparedQuery = PreparedQuery(queryDigits);
    final matched = <ScoredContact>[];

    for (int i = 0; i < _allContacts.length; i++) {
      final c = _allContacts[i];
      final res = VietnameseMatcher.matchPreparedContact(
        contact: c,
        query: preparedQuery,
      );

      if (res.isMatched) {
        matched.add(ScoredContact(
          contact: c,
          matchResult: res,
        ));
      }
    }

    matched.sort((a, b) => b.matchResult.score.compareTo(a.matchResult.score));

    setState(() {
      _dialMatchedContacts = matched.take(6).toList();
    });
  }

  // Dialpad: Insert at current cursor position
  void _onDialpadKeyPress(String char) {
    HapticFeedback.lightImpact();
    final text = _dialController.text;
    final selection = _dialController.selection;

    int start = selection.start;
    int end = selection.end;
    if (start < 0 || end < 0) {
      start = text.length;
      end = text.length;
    }

    final newText = text.replaceRange(start, end, char);
    final newPos = start + char.length;

    _dialController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newPos),
    );
  }

  // Dialpad: Delete digit at cursor position
  void _onDialpadBackspace() {
    final text = _dialController.text;
    final selection = _dialController.selection;
    if (text.isEmpty) return;

    int start = selection.start;
    int end = selection.end;
    if (start < 0 || end < 0) {
      start = text.length;
      end = text.length;
    }

    HapticFeedback.lightImpact();
    if (start != end) {
      final newText = text.replaceRange(start, end, '');
      _dialController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: start),
      );
    } else if (start > 0) {
      final newText = text.replaceRange(start - 1, start, '');
      _dialController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: start - 1),
      );
    }
  }

  void _onDialpadClear() {
    if (_dialController.text.isNotEmpty) {
      HapticFeedback.mediumImpact();
      _dialController.clear();
    }
  }

  Future<void> _callPhone(String phoneNumber) async {
    final cleanPhone = phoneNumber.replaceAll(RegExp(r'\s+'), '');
    if (cleanPhone.isEmpty) return;

    try {
      await _dialerChannel.invokeMethod('callPhone', {'number': cleanPhone});
    } catch (_) {
      final uri = Uri.parse('tel:$cleanPhone');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Không thể gọi đến số $phoneNumber')),
          );
        }
      }
    }
  }

  Future<void> _sendSms(String phoneNumber) async {
    final cleanPhone = phoneNumber.replaceAll(RegExp(r'\s+'), '');
    final uri = Uri.parse('sms:$cleanPhone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không thể nhắn tin đến số $phoneNumber')),
        );
      }
    }
  }

  Future<void> _addNewContact(String phoneNumber) async {
    try {
      await _dialerChannel.invokeMethod('openNewContact', {'number': phoneNumber});
    } catch (_) {}
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text('Đã sao chép: $text'),
          ],
        ),
        backgroundColor: const Color(0xFF2E7D32),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _formatCallDate(int timestampMillis) {
    if (timestampMillis == 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(timestampMillis);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final itemDate = DateTime(date.year, date.month, date.day);

    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');

    if (itemDate == today) {
      return '$hour:$minute';
    } else if (today.difference(itemDate).inDays == 1) {
      return 'Hôm qua $hour:$minute';
    } else {
      final day = date.day.toString().padLeft(2, '0');
      final month = date.month.toString().padLeft(2, '0');
      return '$day/$month $hour:$minute';
    }
  }

  String _formatDuration(int seconds) {
    if (seconds <= 0) return '';
    if (seconds < 60) return '$seconds giây';
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    if (remainingSeconds == 0) return '$minutes phút';
    return '$minutes p $remainingSeconds s';
  }

  String _formatFullCallDate(int timestampMillis) {
    if (timestampMillis == 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(timestampMillis);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final itemDate = DateTime(date.year, date.month, date.day);

    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');

    if (itemDate == today) {
      return 'Hôm nay, $hour:$minute';
    } else if (today.difference(itemDate).inDays == 1) {
      return 'Hôm qua, $hour:$minute';
    } else {
      final day = date.day.toString().padLeft(2, '0');
      final month = date.month.toString().padLeft(2, '0');
      final year = date.year;
      return '$day/$month/$year lúc $hour:$minute';
    }
  }

  String? _resolveContactName(String rawNumber) {
    final clean = VietnameseMatcher.extractDigits(rawNumber);
    if (clean.isEmpty) return null;
    for (int i = 0; i < _allContacts.length; i++) {
      final c = _allContacts[i];
      for (int j = 0; j < c.phones.length; j++) {
        final pDigits = c.phones[j].digits;
        if (pDigits.isEmpty) continue;
        if (pDigits == clean ||
            (pDigits.length >= 9 &&
                clean.length >= 9 &&
                (pDigits.endsWith(clean.substring(clean.length - 9)) ||
                    clean.endsWith(pDigits.substring(pDigits.length - 9))))) {
          return c.displayName;
        }
      }
    }
    return null;
  }

  PreparedContact? _findContactByPhone(String rawNumber) {
    final clean = VietnameseMatcher.extractDigits(rawNumber);
    if (clean.isEmpty) return null;
    for (int i = 0; i < _allContacts.length; i++) {
      final c = _allContacts[i];
      for (int j = 0; j < c.phones.length; j++) {
        final pDigits = c.phones[j].digits;
        if (pDigits.isEmpty) continue;
        if (pDigits == clean ||
            (pDigits.length >= 9 &&
                clean.length >= 9 &&
                (pDigits.endsWith(clean.substring(clean.length - 9)) ||
                    clean.endsWith(pDigits.substring(pDigits.length - 9))))) {
          return c;
        }
      }
    }
    return null;
  }

  void _initiateContactCall(PreparedContact contact) {
    if (contact.phones.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Liên hệ này chưa có số điện thoại')),
      );
      return;
    }
    if (contact.phones.length == 1) {
      _callPhone(contact.phones.first.raw);
    } else {
      _showSelectPhoneDialog(contact);
    }
  }

  void _showSelectPhoneDialog(PreparedContact contact) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: const BoxDecoration(
                        color: Color(0xFFEFF6FF),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.call_rounded, color: Color(0xFF1565C0), size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Chọn số muốn gọi',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                          ),
                          Text(
                            contact.displayName,
                            style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 12),

                ...List.generate(contact.phones.length, (idx) {
                  final phone = contact.phones[idx].raw;
                  final isPrimary = (idx == 0);
                  final label = isPrimary ? 'Số chính' : 'Số phụ $idx';

                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isPrimary ? const Color(0xFFBFDBFE) : Colors.grey.shade200,
                        width: isPrimary ? 1.5 : 1,
                      ),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          Navigator.pop(ctx);
                          _callPhone(phone);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: isPrimary ? const Color(0xFFDBEAFE) : const Color(0xFFFFEDD5),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.bold,
                                    color: isPrimary ? const Color(0xFF1E40AF) : const Color(0xFFC2410C),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  phone,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: const BoxDecoration(
                                  color: Color(0xFFF0FDF4),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.call_rounded, color: Color(0xFF16A34A), size: 20),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showQuickEditContactDialog(PreparedContact? contact, {String? defaultPhone}) {
    final isEditing = (contact != null);
    final nameController = TextEditingController(
      text: isEditing && contact.displayName != 'Không có tên' ? contact.displayName : '',
    );
    final primaryPhoneController = TextEditingController(
      text: isEditing
          ? (contact.phones.isNotEmpty ? contact.phones[0].raw : '')
          : (defaultPhone ?? ''),
    );

    final List<TextEditingController> extraPhoneControllers = [];
    if (isEditing && contact.phones.length > 1) {
      for (int i = 1; i < contact.phones.length; i++) {
        extraPhoneControllers.add(TextEditingController(text: contact.phones[i].raw));
      }
    }

    bool isSaving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.85,
                ),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Header
                      Center(
                        child: Container(
                          width: 44,
                          height: 5,
                          margin: const EdgeInsets.only(top: 12, bottom: 8),
                          decoration: BoxDecoration(
                            color: Colors.grey[300],
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: const BoxDecoration(
                                color: Color(0xFFEFF6FF),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                isEditing ? Icons.edit_note_rounded : Icons.person_add_rounded,
                                color: const Color(0xFF1565C0),
                                size: 24,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                isEditing ? 'Chỉnh sửa liên hệ' : 'Thêm liên hệ mới',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, color: Colors.grey),
                              onPressed: () => Navigator.pop(ctx),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),

                      // Form content
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Name Field
                              const Text(
                                'Họ và tên *',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF334155),
                                ),
                              ),
                              const SizedBox(height: 6),
                              TextField(
                                controller: nameController,
                                textCapitalization: TextCapitalization.words,
                                decoration: InputDecoration(
                                  hintText: 'Nhập tên người liên hệ...',
                                  prefixIcon: const Icon(Icons.person_outline_rounded, color: Color(0xFF1565C0)),
                                  filled: true,
                                  fillColor: const Color(0xFFF8FAFC),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(color: Colors.grey.shade300),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(color: Colors.grey.shade300),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: const BorderSide(color: Color(0xFF1565C0), width: 1.5),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),

                              // Primary Phone Field
                              Row(
                                children: [
                                  const Text(
                                    'Số điện thoại chính *',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF334155),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFDBEAFE),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'Chính',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF1E40AF),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              TextField(
                                controller: primaryPhoneController,
                                keyboardType: TextInputType.phone,
                                decoration: InputDecoration(
                                  hintText: 'Ví dụ: 0912345678',
                                  prefixIcon: const Icon(Icons.phone_rounded, color: Color(0xFF16A34A)),
                                  filled: true,
                                  fillColor: const Color(0xFFF8FAFC),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(color: Colors.grey.shade300),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(color: Colors.grey.shade300),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: const BorderSide(color: Color(0xFF16A34A), width: 1.5),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),

                              // Secondary Phones List
                              if (extraPhoneControllers.isNotEmpty) ...[
                                const Text(
                                  'Số điện thoại phụ',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF334155),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                ...List.generate(extraPhoneControllers.length, (idx) {
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 10),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: TextField(
                                            controller: extraPhoneControllers[idx],
                                            keyboardType: TextInputType.phone,
                                            decoration: InputDecoration(
                                              hintText: 'Số phụ ${idx + 1}...',
                                              prefixIcon: const Icon(Icons.phone_outlined, color: Color(0xFFEA580C)),
                                              filled: true,
                                              fillColor: const Color(0xFFF8FAFC),
                                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                              border: OutlineInputBorder(
                                                borderRadius: BorderRadius.circular(10),
                                                borderSide: BorderSide(color: Colors.grey.shade300),
                                              ),
                                              enabledBorder: OutlineInputBorder(
                                                borderRadius: BorderRadius.circular(10),
                                                borderSide: BorderSide(color: Colors.grey.shade300),
                                              ),
                                              focusedBorder: OutlineInputBorder(
                                                borderRadius: BorderRadius.circular(10),
                                                borderSide: const BorderSide(color: Color(0xFFEA580C), width: 1.5),
                                              ),
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.remove_circle_outline, color: Color(0xFFDC2626)),
                                          tooltip: 'Xóa số phụ này',
                                          onPressed: () {
                                            setModalState(() {
                                              extraPhoneControllers.removeAt(idx);
                                            });
                                          },
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                              ],

                              // Add Extra Phone Button
                              OutlinedButton.icon(
                                icon: const Icon(Icons.add_rounded, size: 20),
                                label: const Text('Thêm số phụ', style: TextStyle(fontWeight: FontWeight.bold)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF1565C0),
                                  side: const BorderSide(color: Color(0xFF93C5FD), width: 1.2),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                ),
                                onPressed: () {
                                  setModalState(() {
                                    extraPhoneControllers.add(TextEditingController());
                                  });
                                },
                              ),
                              const SizedBox(height: 24),

                              // Submit Button
                              SizedBox(
                                width: double.infinity,
                                height: 48,
                                child: ElevatedButton.icon(
                                  icon: isSaving
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                        )
                                      : const Icon(Icons.check_circle_rounded, color: Colors.white),
                                  label: Text(
                                    isSaving ? 'Đang lưu...' : 'Lưu thay đổi',
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF1565C0),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                  onPressed: isSaving
                                      ? null
                                      : () async {
                                          final name = nameController.text.trim();
                                          final primaryPhone = primaryPhoneController.text.trim();

                                          if (name.isEmpty && primaryPhone.isEmpty) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(content: Text('Vui lòng nhập tên hoặc số điện thoại')),
                                            );
                                            return;
                                          }

                                          setModalState(() => isSaving = true);

                                          try {
                                            final phoneNumbers = <Phone>[];
                                            if (primaryPhone.isNotEmpty) {
                                              phoneNumbers.add(Phone(
                                                number: primaryPhone,
                                                isPrimary: true,
                                                label: const Label(PhoneLabel.mobile),
                                              ));
                                            }
                                            for (final epc in extraPhoneControllers) {
                                              final ep = epc.text.trim();
                                              if (ep.isNotEmpty) {
                                                phoneNumbers.add(Phone(
                                                  number: ep,
                                                  isPrimary: false,
                                                  label: const Label(PhoneLabel.work),
                                                ));
                                              }
                                            }

                                            if (isEditing && contact.id.isNotEmpty) {
                                              final existing = await FlutterContacts.get(
                                                contact.id,
                                                properties: {ContactProperty.name, ContactProperty.phone},
                                              );
                                              if (existing != null) {
                                                final updated = existing.copyWith(
                                                  name: Name(first: name.isNotEmpty ? name : 'Không có tên'),
                                                  phones: phoneNumbers,
                                                );
                                                await FlutterContacts.update(updated);
                                              } else {
                                                final newContact = Contact(
                                                  name: Name(first: name.isNotEmpty ? name : 'Không có tên'),
                                                  phones: phoneNumbers,
                                                );
                                                await FlutterContacts.create(newContact);
                                              }
                                            } else {
                                              final newContact = Contact(
                                                name: Name(first: name.isNotEmpty ? name : 'Không có tên'),
                                                phones: phoneNumbers,
                                              );
                                              await FlutterContacts.create(newContact);
                                            }

                                            Navigator.pop(ctx);
                                            _loadContacts();

                                            if (mounted) {
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(
                                                  content: Row(
                                                    children: [
                                                      const Icon(Icons.check_circle, color: Colors.white, size: 20),
                                                      const SizedBox(width: 8),
                                                      Text('Đã lưu thành công danh bạ: ${name.isNotEmpty ? name : primaryPhone}'),
                                                    ],
                                                  ),
                                                  backgroundColor: const Color(0xFF16A34A),
                                                  behavior: SnackBarBehavior.floating,
                                                ),
                                              );
                                            }
                                          } catch (e) {
                                            setModalState(() => isSaving = false);
                                            if (mounted) {
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(content: Text('Lỗi khi lưu danh bạ: $e')),
                                              );
                                            }
                                          }
                                        },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  List<GroupedCallLog> _getGroupedCallLogs(int filter) {
    final sourceLogs = filter == 0
        ? _callLogs
        : _callLogs.where((l) => l.type == 3).toList();

    final Map<String, GroupedCallLog> groupMap = {};
    final List<String> orderedKeys = [];

    for (int i = 0; i < sourceLogs.length; i++) {
      final log = sourceLogs[i];
      var norm = log.number.replaceAll(RegExp(r'[^0-9+]'), '');
      if (norm.startsWith('+84')) {
        norm = '0${norm.substring(3)}';
      } else if (norm.startsWith('84') && norm.length > 9) {
        norm = '0${norm.substring(2)}';
      }
      if (norm.isEmpty) norm = log.number;

      if (!groupMap.containsKey(norm)) {
        final contactName = _resolveContactName(log.number) ?? log.name;
        groupMap[norm] = GroupedCallLog(
          normalizedNumber: norm,
          rawNumber: log.number,
          name: contactName,
          calls: [log],
        );
        orderedKeys.add(norm);
      } else {
        groupMap[norm]!.calls.add(log);
      }
    }

    return orderedKeys.map((k) => groupMap[k]!).toList();
  }

  Color _getCallTypeBgColor(int type, int duration) {
    if (type == 3 || (type == 2 && duration == 0)) {
      return const Color(0xFFFEF2F2);
    }
    if (type == 2) {
      return const Color(0xFFF0FDF4);
    }
    if (type == 1) {
      return const Color(0xFFEFF6FF);
    }
    return const Color(0xFFF8FAFC);
  }

  void _showCallHistoryDialog(GroupedCallLog group) {
    final displayName = (group.name != null && group.name!.isNotEmpty)
        ? group.name!
        : group.rawNumber;
    final hasName = (group.name != null && group.name!.isNotEmpty);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 44,
                    height: 5,
                    margin: const EdgeInsets.only(top: 12, bottom: 8),
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),

                // Contact Header Card
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Column(
                    children: [
                      // Avatar Circle
                      Container(
                        width: 68,
                        height: 68,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: hasName
                                ? [const Color(0xFF1E88E5), const Color(0xFF1565C0)]
                                : [const Color(0xFF64748B), const Color(0xFF475569)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            hasName ? displayName.trim().characters.first.toUpperCase() : '#',
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        displayName,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0F172A),
                        ),
                        textAlign: TextAlign.center,
                      ),
                      if (hasName) ...[
                        const SizedBox(height: 4),
                        Text(
                          group.rawNumber,
                          style: TextStyle(fontSize: 15, color: Colors.grey[600]),
                        ),
                      ],
                      const SizedBox(height: 16),

                      // Actions Row: Gọi, Nhắn tin, Sao chép, Lưu số
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildActionButton(
                            icon: Icons.call_rounded,
                            label: 'Gọi điện',
                            color: const Color(0xFF16A34A),
                            onTap: () {
                              Navigator.pop(ctx);
                              final c = _findContactByPhone(group.rawNumber);
                              if (c != null && c.phones.length > 1) {
                                _showSelectPhoneDialog(c);
                              } else {
                                _callPhone(group.rawNumber);
                              }
                            },
                          ),
                          _buildActionButton(
                            icon: Icons.message_rounded,
                            label: 'Nhắn tin',
                            color: const Color(0xFF0284C7),
                            onTap: () {
                              Navigator.pop(ctx);
                              _sendSms(group.rawNumber);
                            },
                          ),
                          _buildActionButton(
                            icon: Icons.copy_rounded,
                            label: 'Sao chép',
                            color: Colors.grey.shade700,
                            onTap: () {
                              Navigator.pop(ctx);
                              _copyToClipboard(group.rawNumber);
                            },
                          ),
                          _buildActionButton(
                            icon: hasName ? Icons.edit_note_rounded : Icons.person_add_rounded,
                            label: hasName ? 'Sửa liên hệ' : 'Lưu số',
                            color: const Color(0xFF1565C0),
                            onTap: () {
                              Navigator.pop(ctx);
                              final c = _findContactByPhone(group.rawNumber);
                              _showQuickEditContactDialog(c, defaultPhone: group.rawNumber);
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const Divider(height: 1, thickness: 1),

                // History Section Title
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  color: const Color(0xFFF8FAFC),
                  child: Row(
                    children: [
                      const Icon(Icons.history_rounded, size: 18, color: Color(0xFF475569)),
                      const SizedBox(width: 6),
                      Text(
                        'LỊCH SỬ CUỘC GỌI (${group.count} lần)',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF475569),
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),

                const Divider(height: 1, thickness: 1),

                // List of Calls
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: group.calls.length,
                    separatorBuilder: (context, index) => Divider(
                      height: 1,
                      indent: 64,
                      color: Colors.grey.shade100,
                    ),
                    itemBuilder: (context, index) {
                      final call = group.calls[index];
                      final isMissed = (call.type == 3);
                      final isOutgoing = (call.type == 2);
                      final isIncoming = (call.type == 1);
                      final isRejected = (call.type == 5);

                      String callStatusTitle;
                      Color statusColor = const Color(0xFF0F172A);
                      if (isOutgoing) {
                        if (call.duration > 0) {
                          callStatusTitle = 'Cuộc gọi đi';
                        } else {
                          callStatusTitle = 'Đổ chuông không nghe máy';
                          statusColor = const Color(0xFFD97706);
                        }
                      } else if (isIncoming) {
                        if (call.duration > 0) {
                          callStatusTitle = 'Cuộc gọi đến';
                        } else {
                          callStatusTitle = 'Cuộc gọi nhỡ';
                          statusColor = const Color(0xFFDC2626);
                        }
                      } else if (isMissed) {
                        callStatusTitle = 'Cuộc gọi nhỡ';
                        statusColor = const Color(0xFFDC2626);
                      } else if (isRejected) {
                        callStatusTitle = 'Từ chối cuộc gọi';
                        statusColor = const Color(0xFFEA580C);
                      } else {
                        callStatusTitle = 'Cuộc gọi';
                      }

                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Call icon with background circle
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: _getCallTypeBgColor(call.type, call.duration),
                                shape: BoxShape.circle,
                              ),
                              child: _buildCallTypeIcon(call.type, size: 18),
                            ),
                            const SizedBox(width: 14),

                            // Call detail text
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    callStatusTitle,
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      color: statusColor,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  if (call.duration > 0) ...[
                                    Text(
                                      'Thời lượng: ${_formatDuration(call.duration)}',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.grey[700],
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                  ],
                                  Text(
                                    _formatFullCallDate(call.date),
                                    style: TextStyle(fontSize: 12.5, color: Colors.grey[500]),
                                  ),
                                ],
                              ),
                            ),

                            // Time on right
                            Text(
                              _formatCallDate(call.date),
                              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: Colors.grey[600]),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Colors.grey[800])),
          ],
        ),
      ),
    );
  }

  Icon _buildCallTypeIcon(int type, {double size = 18}) {
    switch (type) {
      case 1: // Incoming
        return Icon(Icons.call_received_rounded, size: size, color: const Color(0xFF2563EB));
      case 2: // Outgoing
        return Icon(Icons.call_made_rounded, size: size, color: const Color(0xFF16A34A));
      case 3: // Missed
        return Icon(Icons.call_missed_rounded, size: size, color: const Color(0xFFDC2626));
      default:
        return Icon(Icons.phone_missed_rounded, size: size, color: Colors.grey);
    }
  }

  String _getCallTypeName(int type) {
    switch (type) {
      case 1:
        return 'Cuộc gọi đến';
      case 2:
        return 'Cuộc gọi đi';
      case 3:
        return 'Cuộc gọi nhỡ';
      case 5:
        return 'Từ chối cuộc gọi';
      default:
        return 'Cuộc gọi';
    }
  }

  void _showContactActionDialog(PreparedContact contact, Map<String, List<MatchHighlight>> phoneHighlights) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            contact.displayName,
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${contact.phones.length} số điện thoại lưu trữ',
                            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showQuickEditContactDialog(contact);
                      },
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('Sửa liên hệ', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFEFF6FF),
                        foregroundColor: const Color(0xFF1D4ED8),
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: const BorderSide(color: Color(0xFFBFDBFE)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Divider(height: 1),
                const SizedBox(height: 12),

                if (contact.phones.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Liên hệ này không có số điện thoại.',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  )
                else
                  ...contact.phones.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final p = entry.value;
                    final phone = p.raw;
                    final hl = phoneHighlights[phone] ?? [];
                    final isPrimary = idx == 0;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isPrimary ? const Color(0xFFBFDBFE) : Colors.grey.shade200,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            margin: const EdgeInsets.only(right: 10),
                            decoration: BoxDecoration(
                              color: isPrimary ? const Color(0xFFDBEAFE) : const Color(0xFFFEF3C7),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              isPrimary ? 'Chính' : 'Phụ $idx',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: isPrimary ? const Color(0xFF1D4ED8) : const Color(0xFFB45309),
                              ),
                            ),
                          ),
                          Expanded(
                            child: _buildFastHighlightedText(
                              text: phone,
                              highlights: hl,
                              baseStyle: _phoneBaseStyle.copyWith(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF1E293B),
                              ),
                              highlightStyle: _phoneHighlightStyle.copyWith(fontSize: 16),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy, size: 20, color: Colors.grey),
                            tooltip: 'Sao chép',
                            onPressed: () => _copyToClipboard(phone),
                          ),
                          IconButton(
                            icon: const Icon(Icons.message, size: 22, color: Color(0xFF0284C7)),
                            tooltip: 'Nhắn tin',
                            onPressed: () {
                              Navigator.pop(ctx);
                              _sendSms(phone);
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.call, size: 24, color: Color(0xFF16A34A)),
                            tooltip: 'Gọi điện',
                            onPressed: () {
                              Navigator.pop(ctx);
                              _callPhone(phone);
                            },
                          ),
                        ],
                      ),
                    );
                  }),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  static Widget _buildFastHighlightedText({
    required String text,
    required List<MatchHighlight> highlights,
    required TextStyle baseStyle,
    required TextStyle highlightStyle,
  }) {
    if (highlights.isEmpty) {
      return Text(text, style: baseStyle, overflow: TextOverflow.ellipsis);
    }

    final spans = <TextSpan>[];
    int current = 0;

    for (int i = 0; i < highlights.length; i++) {
      final h = highlights[i];
      final start = h.start.clamp(0, text.length);
      final end = h.end.clamp(0, text.length);

      if (start > current) {
        spans.add(TextSpan(
          text: text.substring(current, start),
          style: baseStyle,
        ));
      }

      if (end > start) {
        spans.add(TextSpan(
          text: text.substring(start, end),
          style: highlightStyle,
        ));
      }
      current = end;
    }

    if (current < text.length) {
      spans.add(TextSpan(
        text: text.substring(current),
        style: baseStyle,
      ));
    }

    return RichText(
      text: TextSpan(children: spans),
      overflow: TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Danh Bạ Pro by Thông Tô',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(
              _currentTabIndex == 0
                  ? 'Gần đây • Nhật ký cuộc gọi'
                  : (_currentTabIndex == 1
                      ? 'Bàn phím quay số thông minh'
                      : 'Tìm số & tên tiếng Việt thông minh'),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal, color: Colors.white70),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Làm mới',
            onPressed: () {
              _loadContacts();
              _loadCallLogs();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Banner asking to set as Default Dialer if not yet default
          if (!_isDefaultDialer)
            Container(
              color: const Color(0xFFFEF3C7),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.phone_in_talk, color: Color(0xFFB45309), size: 19),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Đặt làm ứng dụng gọi điện mặc định',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF92400E),
                      ),
                    ),
                  ),
                  ElevatedButton(
                    onPressed: _requestDefaultDialer,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1565C0),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    child: const Text('Cài đặt ngay', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),

          Expanded(
            child: IndexedStack(
              index: _currentTabIndex,
              children: [
                _buildCallLogsTab(),
                _buildDialpadTab(),
                _buildContactsTab(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Colors.grey.shade200, width: 1)),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentTabIndex,
          elevation: 0,
          backgroundColor: Colors.transparent,
          selectedItemColor: const Color(0xFF1565C0),
          unselectedItemColor: Colors.grey[500],
          selectedFontSize: 13,
          unselectedFontSize: 12,
          type: BottomNavigationBarType.fixed,
          onTap: (index) {
            setState(() {
              _currentTabIndex = index;
            });
          },
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.access_time_rounded),
              activeIcon: Icon(Icons.access_time_filled_rounded, color: Color(0xFF1565C0)),
              label: 'Gần đây',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.dialpad_rounded),
              activeIcon: Icon(Icons.dialpad_rounded, color: Color(0xFF1565C0)),
              label: 'Bàn phím',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.contacts_rounded),
              activeIcon: Icon(Icons.contacts_rounded, color: Color(0xFF1565C0)),
              label: 'Danh bạ',
            ),
          ],
        ),
      ),
    );
  }

  // ==================== TAB 0: GẦN ĐÂY (CALL LOGS) ====================
  Widget _buildCallLogsTab() {
    final groupedLogs = _getGroupedCallLogs(_callLogFilter);

    return Column(
      children: [
        // Filter Header: Tất cả / Cuộc gọi nhỡ
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
          ),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('Tất cả'),
                selected: _callLogFilter == 0,
                selectedColor: const Color(0xFFDBEAFE),
                labelStyle: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: _callLogFilter == 0 ? const Color(0xFF1D4ED8) : Colors.grey[700],
                ),
                onSelected: (val) {
                  if (val) setState(() => _callLogFilter = 0);
                },
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Cuộc gọi nhỡ'),
                selected: _callLogFilter == 1,
                selectedColor: const Color(0xFFFEE2E2),
                labelStyle: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: _callLogFilter == 1 ? const Color(0xFFDC2626) : Colors.grey[700],
                ),
                onSelected: (val) {
                  if (val) setState(() => _callLogFilter = 1);
                },
              ),
              const Spacer(),
              Text(
                '${groupedLogs.length} người liên hệ',
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
            ],
          ),
        ),

        Expanded(
          child: _isLoadingCallLogs
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Đang nạp nhật ký cuộc gọi...'),
                    ],
                  ),
                )
              : (groupedLogs.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.call_end_outlined, size: 52, color: Colors.grey[300]),
                          const SizedBox(height: 8),
                          Text(
                            _callLogFilter == 1
                                ? 'Không có cuộc gọi nhỡ nào'
                                : 'Chưa có lịch sử cuộc gọi',
                            style: TextStyle(color: Colors.grey[500], fontSize: 14),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadCallLogs,
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics()),
                        itemCount: groupedLogs.length,
                        itemBuilder: (context, index) {
                          final group = groupedLogs[index];
                          final latest = group.latestCall;
                          final isMissed = (latest.type == 3);
                          final displayName = (group.name != null && group.name!.isNotEmpty)
                              ? group.name!
                              : group.rawNumber;
                          final hasName = (group.name != null && group.name!.isNotEmpty);

                          return Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border(bottom: BorderSide(color: Colors.grey.shade100, width: 0.8)),
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () => _showCallHistoryDialog(group),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                  child: Row(
                                    children: [
                                      // Call Type Icon
                                      _buildCallTypeIcon(latest.type, size: 20),
                                      const SizedBox(width: 14),
                                      // Name / Number & Count
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Row(
                                              children: [
                                                Flexible(
                                                  child: Text(
                                                    displayName,
                                                    style: TextStyle(
                                                      fontSize: 15.5,
                                                      fontWeight: FontWeight.bold,
                                                      color: isMissed
                                                          ? const Color(0xFFDC2626)
                                                          : const Color(0xFF0F172A),
                                                    ),
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                if (group.count > 1) ...[
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    '(${group.count})',
                                                    style: TextStyle(
                                                      fontSize: 14.5,
                                                      fontWeight: FontWeight.bold,
                                                      color: isMissed
                                                          ? const Color(0xFFDC2626)
                                                          : const Color(0xFF1565C0),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                            const SizedBox(height: 2),
                                            Row(
                                              children: [
                                                if (hasName) ...[
                                                  Text(
                                                    group.rawNumber,
                                                    style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                                                  ),
                                                  const SizedBox(width: 8),
                                                ],
                                                if (latest.duration > 0) ...[
                                                  Text(
                                                    _formatDuration(latest.duration),
                                                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                                                  ),
                                                ] else if (latest.type == 2) ...[
                                                  const Text(
                                                    'Đổ chuông không nghe máy',
                                                    style: TextStyle(fontSize: 12, color: Color(0xFFD97706)),
                                                  ),
                                                ] else if (latest.type == 3) ...[
                                                  const Text(
                                                    'Cuộc gọi nhỡ',
                                                    style: TextStyle(fontSize: 12, color: Color(0xFFDC2626)),
                                                  ),
                                                ] else if (latest.type == 5) ...[
                                                  const Text(
                                                    'Từ chối cuộc gọi',
                                                    style: TextStyle(fontSize: 12, color: Colors.grey),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                      // Date & Call Button
                                      Text(
                                        _formatCallDate(latest.date),
                                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                                      ),
                                      const SizedBox(width: 8),
                                      GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () => _callPhone(group.rawNumber),
                                        child: Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF0FDF4),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: const Icon(
                                            Icons.call_rounded,
                                            color: Color(0xFF16A34A),
                                            size: 20,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    )),
        ),
      ],
    );
  }

  // ==================== TAB 1: BÀN PHÍM QUAY SỐ (DIALPAD) ====================
  Widget _buildDialpadTab() {
    return Column(
      children: [
        // Upper section: Matched contacts or hints
        Expanded(
          child: _dialMatchedContacts.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.dialer_sip_outlined, size: 50, color: Colors.grey[300]),
                      const SizedBox(height: 8),
                      Text(
                        _dialController.text.isEmpty
                            ? 'Bấm số để gọi điện'
                            : 'Không tìm thấy liên hệ trùng khớp',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[500],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _dialMatchedContacts.length,
                  itemBuilder: (context, index) {
                    final item = _dialMatchedContacts[index];
                    final contact = item.contact;
                    final match = item.matchResult;

                    String displayPhone = '';
                    List<MatchHighlight> displayHighlights = const [];
                    for (final p in contact.phones) {
                      final hl = match.phoneHighlights[p.raw];
                      if (hl != null && hl.isNotEmpty) {
                        displayPhone = p.raw;
                        displayHighlights = hl;
                        break;
                      }
                    }
                    if (displayPhone.isEmpty && contact.phones.isNotEmpty) {
                      displayPhone = contact.phones.first.raw;
                    }

                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
                      ),
                      child: ListTile(
                        dense: true,
                        title: Text(
                          contact.displayName,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        subtitle: _buildFastHighlightedText(
                          text: displayPhone,
                          highlights: displayHighlights,
                          baseStyle: _phoneBaseStyle,
                          highlightStyle: _phoneHighlightStyle,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, color: Color(0xFF64748B), size: 20),
                              tooltip: 'Sửa liên hệ',
                              onPressed: () => _showQuickEditContactDialog(contact),
                            ),
                            IconButton(
                              icon: const Icon(Icons.call_rounded, color: Color(0xFF16A34A)),
                              tooltip: 'Gọi điện',
                              onPressed: () => _initiateContactCall(contact),
                            ),
                          ],
                        ),
                        onTap: () {
                          final clean = displayPhone.replaceAll(RegExp(r'\s+'), '');
                          _dialController.value = TextEditingValue(
                            text: clean,
                            selection: TextSelection.collapsed(offset: clean.length),
                          );
                        },
                      ),
                    );
                  },
                ),
        ),

        // Middle: Number display area with interactive moveable cursor & Backspace
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Colors.grey.shade100)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const SizedBox(width: 36),
                  // Interactive moveable cursor TextField
                  Expanded(
                    child: TextField(
                      controller: _dialController,
                      readOnly: true, // Don't show system soft keyboard
                      showCursor: true, // Show the moveable blinking cursor
                      autofocus: false,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2.0,
                        color: Color(0xFF0F172A),
                      ),
                      cursorColor: const Color(0xFF1565C0),
                      cursorWidth: 3.0,
                      cursorRadius: const Radius.circular(2),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  if (_dialController.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.backspace_outlined, size: 22, color: Colors.grey),
                      onPressed: _onDialpadBackspace,
                      onLongPress: _onDialpadClear,
                      tooltip: 'Xóa (Giữ để xóa hết)',
                    )
                  else
                    const SizedBox(width: 48),
                ],
              ),
              // Option to save new contact
              if (_dialController.text.isNotEmpty)
                TextButton.icon(
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 16, color: Color(0xFF1565C0)),
                  label: const Text('Thêm vào danh bạ', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => _addNewContact(_dialController.text),
                ),
            ],
          ),
        ),

        const Divider(height: 1),

        // Keypad area (12 Keys + Call Button)
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 14),
          child: Column(
            children: [
              _buildKeypadRow('1', '', '2', 'ABC', '3', 'DEF'),
              const SizedBox(height: 8),
              _buildKeypadRow('4', 'GHI', '5', 'JKL', '6', 'MNO'),
              const SizedBox(height: 8),
              _buildKeypadRow('7', 'PQRS', '8', 'TUV', '9', 'WXYZ'),
              const SizedBox(height: 8),
              _buildKeypadRow('*', '', '0', '+', '#', ''),
              const SizedBox(height: 12),

              // Bottom Call Action Row
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: () {
                      if (_dialController.text.isNotEmpty) {
                        HapticFeedback.mediumImpact();
                        _callPhone(_dialController.text);
                      }
                    },
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: const Color(0xFF16A34A),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF16A34A).withOpacity(0.35),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.call_rounded, color: Colors.white, size: 30),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildKeypadRow(
    String d1, String l1,
    String d2, String l2,
    String d3, String l3,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildKeypadButton(d1, l1),
        _buildKeypadButton(d2, l2),
        _buildKeypadButton(d3, l3),
      ],
    );
  }

  Widget _buildKeypadButton(String digit, String letters) {
    return InkWell(
      borderRadius: BorderRadius.circular(35),
      onTap: () => _onDialpadKeyPress(digit),
      onLongPress: digit == '0' ? () => _onDialpadKeyPress('+') : null,
      child: Container(
        width: 68,
        height: 58,
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(29),
          border: Border.all(color: Colors.grey.shade200, width: 0.8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              digit,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1E293B),
                height: 1.1,
              ),
            ),
            if (letters.isNotEmpty)
              Text(
                letters,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                  color: Colors.grey[500],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ==================== TAB 2: DANH BẠ (CONTACTS) ====================
  Widget _buildContactsTab() {
    return Column(
      children: [
        // Search Header Area
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _searchController,
                autofocus: false,
                decoration: InputDecoration(
                  hintText: 'Nhập dãy số (VD: 8386) hoặc tên (VD: 3 d 4 diêm 1)...',
                  hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13.5),
                  prefixIcon: const Icon(Icons.search, color: Color(0xFF1565C0)),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.grey),
                          onPressed: () {
                            _searchController.clear();
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: const Color(0xFFF1F5F9),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF1565C0), width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _isLoadingContacts
                        ? 'Đang tải danh bạ...'
                        : 'Hiển thị ${_filteredContacts.length} / ${_allContacts.length} danh bạ',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey[700],
                    ),
                  ),
                  if (_searchController.text.trim().isNotEmpty)
                    () {
                      final isNameSearch = RegExp(r'[\p{L}]', unicode: true)
                          .hasMatch(_searchController.text.trim());
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: isNameSearch ? const Color(0xFFEFF6FF) : const Color(0xFFFEF3C7),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: isNameSearch ? const Color(0xFF3B82F6) : const Color(0xFFF59E0B),
                          ),
                        ),
                        child: Text(
                          isNameSearch ? 'Chỉ khớp tên' : 'Chỉ khớp số điện thoại',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: isNameSearch ? const Color(0xFF1D4ED8) : const Color(0xFFB45309),
                          ),
                        ),
                      );
                    }(),
                ],
              ),
            ],
          ),
        ),

        // Main Contact List
        Expanded(
          child: _buildContactsList(),
        ),
      ],
    );
  }

  Widget _buildContactsList() {
    if (_isLoadingContacts) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Đang nạp danh bạ...', style: TextStyle(fontSize: 15)),
          ],
        ),
      );
    }

    if (_permissionDenied) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.security, size: 60, color: Colors.orange),
              const SizedBox(height: 16),
              const Text(
                'Cần quyền truy cập Danh Bạ',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Ứng dụng cần quyền đọc danh bạ để tìm kiếm số điện thoại và tên.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey[600]),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                icon: const Icon(Icons.security),
                label: const Text('Cấp quyền ngay'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () async {
                  final status = await FlutterContacts.permissions.request(PermissionType.read);
                  if (status == PermissionStatus.permanentlyDenied || status == PermissionStatus.denied) {
                    await FlutterContacts.permissions.openSettings();
                  }
                  _loadContacts();
                },
              ),
            ],
          ),
        ),
      );
    }

    if (_filteredContacts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 50, color: Colors.grey[400]),
            const SizedBox(height: 10),
            Text(
              'Không tìm thấy danh bạ phù hợp',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.grey[700]),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      physics: const ClampingScrollPhysics(),
      cacheExtent: 600,
      itemCount: _filteredContacts.length,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: true,
      itemBuilder: (context, index) {
        final item = _filteredContacts[index];
        final contact = item.contact;
        final match = item.matchResult;

        String displayPhone = '';
        List<MatchHighlight> displayPhoneHighlights = const [];
        if (contact.phones.isNotEmpty) {
          for (final p in contact.phones) {
            final hl = match.phoneHighlights[p.raw];
            if (hl != null && hl.isNotEmpty) {
              displayPhone = p.raw;
              displayPhoneHighlights = hl;
              break;
            }
          }
          if (displayPhone.isEmpty) {
            displayPhone = contact.phones.first.raw;
          }
        }

        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(
              bottom: BorderSide(color: Colors.grey.shade100, width: 1),
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _showContactActionDialog(contact, match.phoneHighlights),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildFastHighlightedText(
                            text: contact.displayName,
                            highlights: match.nameHighlights,
                            baseStyle: _nameBaseStyle,
                            highlightStyle: _nameHighlightStyle,
                          ),
                          const SizedBox(height: 3),
                          if (displayPhone.isNotEmpty)
                            Row(
                              children: [
                                _buildFastHighlightedText(
                                  text: displayPhone,
                                  highlights: displayPhoneHighlights,
                                  baseStyle: _phoneBaseStyle,
                                  highlightStyle: _phoneHighlightStyle,
                                ),
                                if (contact.phones.length > 1) ...[
                                  const SizedBox(width: 8),
                                  Text(
                                    '(+${contact.phones.length - 1} số)',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade500,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ],
                            )
                          else
                            Text(
                              'Không có số',
                              style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                            ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _showQuickEditContactDialog(contact),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.edit_outlined,
                              color: Color(0xFF475569),
                              size: 19,
                            ),
                          ),
                        ),
                        if (displayPhone.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _initiateContactCall(contact),
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF0FDF4),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                Icons.call_rounded,
                                color: Color(0xFF16A34A),
                                size: 20,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
