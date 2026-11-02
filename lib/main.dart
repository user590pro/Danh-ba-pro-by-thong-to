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

class MainHomeScreen extends StatefulWidget {
  const MainHomeScreen({super.key});

  @override
  State<MainHomeScreen> createState() => _MainHomeScreenState();
}

class _MainHomeScreenState extends State<MainHomeScreen> with WidgetsBindingObserver {
  static const MethodChannel _dialerChannel = MethodChannel('com.antigravity.contactfinder/dialer');

  int _currentTabIndex = 0;
  List<PreparedContact> _allContacts = [];
  bool _isLoading = true;
  bool _permissionDenied = false;
  bool _isDefaultDialer = true; // Default to true until checked

  // Dialpad state with text controller for cursor positioning and editing anywhere
  final TextEditingController _dialController = TextEditingController();
  List<ScoredContact> _dialMatchedContacts = [];

  // Search state
  final TextEditingController _searchController = TextEditingController();
  List<ScoredContact> _filteredContacts = [];
  String _currentQuery = '';
  Timer? _debounceTimer;

  // Cached static styles for 120 FPS performance
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

  Future<void> _loadContacts() async {
    setState(() {
      _isLoading = true;
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
          _isLoading = false;
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
        _isLoading = false;
      });
      _filterContacts(_searchController.text);
      _updateDialpadMatches();
    } catch (e) {
      setState(() {
        _isLoading = false;
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

  void _showActionDialog(PreparedContact contact, Map<String, List<MatchHighlight>> phoneHighlights) {
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
                  ...contact.phones.map((p) {
                    final phone = p.raw;
                    final hl = phoneHighlights[phone] ?? [];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Row(
                        children: [
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
              _currentTabIndex == 0 ? 'Bàn phím quay số thông minh' : 'Tìm số & tên tiếng Việt thông minh',
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
            tooltip: 'Làm mới danh bạ',
            onPressed: _loadContacts,
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
                        trailing: IconButton(
                          icon: const Icon(Icons.call_rounded, color: Color(0xFF16A34A)),
                          onPressed: () => _callPhone(displayPhone),
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
          child: Row(
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
                    _isLoading
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
    if (_isLoading) {
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
              onTap: () => _showActionDialog(contact, match.phoneHighlights),
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
                    if (displayPhone.isNotEmpty)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _callPhone(displayPhone),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          margin: const EdgeInsets.only(left: 8),
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
    );
  }
}
