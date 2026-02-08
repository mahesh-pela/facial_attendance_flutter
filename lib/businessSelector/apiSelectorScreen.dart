import 'package:dio/dio.dart';
import 'package:face_attendance/splashScreen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../manager/dioErrorManager.dart';
import 'apiSelectorByBusinessCode.dart';

class ApiSelectorScreen extends StatefulWidget {
  const ApiSelectorScreen({super.key});

  @override
  State<ApiSelectorScreen> createState() => ApiSelectorScreenState();
}

class ApiSelectorScreenState extends State<ApiSelectorScreen> {
  final TextEditingController apiUrlController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool isLoading = false;
  bool _hasError = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    apiUrlController.text = "https://api.bizforce360.com";

    // Listen to text changes to clear errors
    apiUrlController.addListener(() {
      if (_hasError && apiUrlController.text.isNotEmpty) {
        setState(() {
          _hasError = false;
          _errorMessage = null;
        });
      }
    });
  }

  @override
  void dispose() {
    apiUrlController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // Validate URL format
  bool _isValidUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https');
    } catch (e) {
      return false;
    }
  }

  // Function to validate and connect to server
  Future<void> connectToServer() async {
    // Unfocus to dismiss keyboard
    _focusNode.unfocus();

    final serverUrl = apiUrlController.text.trim();

    // Validation
    if (serverUrl.isEmpty) {
      setState(() {
        _hasError = true;
        _errorMessage = 'Please enter server URL';
      });
      return;
    }

    if (!_isValidUrl(serverUrl)) {
      setState(() {
        _hasError = true;
        _errorMessage = 'Please enter a valid URL (e.g., https://example.com)';
      });
      return;
    }

    if (mounted) {
      setState(() {
        isLoading = true;
        _hasError = false;
        _errorMessage = null;
      });
    }

    try {
      String cleanUrl = serverUrl;
      if (cleanUrl.endsWith('/')) {
        cleanUrl = cleanUrl.substring(0, cleanUrl.length - 1);
      }

      debugPrint("Connecting to: $cleanUrl");

      // Verify server is accessible
      final response = await Dio().get("$cleanUrl/check-server");
      debugPrint("Server response: $response");

      // Save to shared preferences
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('apiURL', cleanUrl);

      // Navigate to splash screen
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const Splashscreen()),
              (route) => false,
        );
      }
    } on DioException catch (e) {
      if (mounted) {
        setState(() {
          _hasError = true;
          if (e.response?.statusCode == 404) {
            _errorMessage = 'Server not found. Please check the URL.';
          } else if (e.type == DioExceptionType.connectionTimeout ||
              e.type == DioExceptionType.receiveTimeout) {
            _errorMessage = 'Connection timeout. Please try again.';
          } else if (e.type == DioExceptionType.connectionError) {
            _errorMessage = 'Unable to connect. Please check the URL and your internet connection.';
          } else {
            _errorMessage = 'Failed to connect to server. Please try again.';
          }
        });
      }
      dioErrorManager(e);
      debugPrint("Connection error: $e");
    } catch (e) {
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = 'An unexpected error occurred. Please try again.';
        });
      }
      debugPrint("Error: $e");
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  void _launchURL(String urlString) async {
    final Uri url = Uri.parse(urlString);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: isDark ? null : Colors.grey[50],
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 40),

                // Logo section
                Center(
                  child: Container(
                    height: 100.0,
                    width: 100.0,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24.0),
                      boxShadow: [
                        BoxShadow(
                          color: colorScheme.primary.withOpacity(0.08),
                          blurRadius: 20.0,
                          offset: const Offset(0, 8),
                        ),
                        BoxShadow(
                          color: Colors.black.withOpacity(0.04),
                          blurRadius: 10.0,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24.0),
                      child: Image.asset(
                        "assets/images/faceAttendance.png",
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 48.0),

                // Title
                Text(
                  'Server Configuration',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28.0,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.grey[900],
                    letterSpacing: -0.5,
                  ),
                ),

                const SizedBox(height: 12.0),

                // Subtitle
                Text(
                  'Enter your server URL to connect',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16.0,
                    color: isDark ? Colors.grey[400] : Colors.grey[600],
                    height: 1.5,
                  ),
                ),

                const SizedBox(height: 40),

                // Server URL Input Field
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16.0),
                    boxShadow: _hasError
                        ? null
                        : [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.04),
                        blurRadius: 8.0,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: TextFormField(
                    controller: apiUrlController,
                    focusNode: _focusNode,
                    enabled: !isLoading,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => connectToServer(),
                    style: TextStyle(
                      fontSize: 16.0,
                      fontWeight: FontWeight.w500,
                      color: isDark ? Colors.white : Colors.grey[900],
                    ),
                    decoration: InputDecoration(
                      hintText: 'https://example.com',
                      labelText: 'Server URL',
                      labelStyle: TextStyle(
                        color: _hasError
                            ? colorScheme.error
                            : isDark
                            ? Colors.grey[400]
                            : Colors.grey[600],
                      ),
                      prefixIcon: Icon(
                        Icons.language_outlined,
                        color: _hasError
                            ? colorScheme.error
                            : colorScheme.primary,
                        size: 22,
                      ),
                      suffixIcon: apiUrlController.text.isNotEmpty && !isLoading
                          ? IconButton(
                        icon: Icon(
                          Icons.clear,
                          color: Colors.grey[400],
                          size: 20,
                        ),
                        onPressed: () {
                          apiUrlController.clear();
                          setState(() {
                            _hasError = false;
                            _errorMessage = null;
                          });
                        },
                      )
                          : null,
                      filled: true,
                      fillColor: isDark
                          ? Colors.grey[850]
                          : _hasError
                          ? colorScheme.error.withOpacity(0.05)
                          : Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16.0),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16.0),
                        borderSide: BorderSide(
                          color: _hasError
                              ? colorScheme.error
                              : isDark
                              ? Colors.grey[700]!
                              : Colors.grey[200]!,
                          width: 1.5,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16.0),
                        borderSide: BorderSide(
                          color: _hasError
                              ? colorScheme.error
                              : colorScheme.primary,
                          width: 2.0,
                        ),
                      ),
                      errorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16.0),
                        borderSide: BorderSide(
                          color: colorScheme.error,
                          width: 1.5,
                        ),
                      ),
                      focusedErrorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16.0),
                        borderSide: BorderSide(
                          color: colorScheme.error,
                          width: 2.0,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20.0,
                        vertical: 18.0,
                      ),
                    ),
                  ),
                ),

                // Error message
                if (_hasError && _errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0, left: 4.0),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 16,
                          color: colorScheme.error,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(
                              fontSize: 13.0,
                              color: colorScheme.error,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                const SizedBox(height: 32),

                // Connect button
                SizedBox(
                  height: 56.0,
                  child: ElevatedButton(
                    onPressed: isLoading ? null : connectToServer,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colorScheme.primary,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: isDark
                          ? Colors.grey[800]
                          : Colors.grey[300],
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16.0),
                      ),
                      elevation: isLoading ? 0 : 2.0,
                      shadowColor: colorScheme.primary.withOpacity(0.3),
                    ),
                    child: isLoading
                        ? const SizedBox(
                      height: 24.0,
                      width: 24.0,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor:
                        AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                        : const Text(
                      'Connect to Server',
                      style: TextStyle(
                        fontSize: 16.0,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // Divider with "Or"
                Row(
                  children: [
                    Expanded(
                      child: Divider(
                        color: isDark ? Colors.grey[700] : Colors.grey[300],
                        thickness: 1,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Text(
                        'OR',
                        style: TextStyle(
                          fontSize: 13.0,
                          fontWeight: FontWeight.w500,
                          color: isDark ? Colors.grey[500] : Colors.grey[500],
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Divider(
                        color: isDark ? Colors.grey[700] : Colors.grey[300],
                        thickness: 1,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // Alternative connection method
                OutlinedButton(
                  onPressed: isLoading
                      ? null
                      : () {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                        const ApiSelectorByBusinessCodeScreen(),
                      ),
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colorScheme.primary,
                    side: BorderSide(
                      color: isDark ? Colors.grey[700]! : Colors.grey[300]!,
                      width: 1.5,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16.0),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 16.0),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.business_center_outlined,
                        size: 20,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Connect using Business Code',
                        style: TextStyle(
                          fontSize: 15.0,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.primary,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 32),

                // Terms and Privacy Policy
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: TextStyle(
                        fontSize: 13.0,
                        color: isDark ? Colors.grey[500] : Colors.grey[600],
                        height: 1.6,
                      ),
                      children: [
                        const TextSpan(
                          text:
                          "By continuing, you confirm that you have read and agree to our ",
                        ),
                        TextSpan(
                          text: "Terms and Conditions",
                          recognizer: TapGestureRecognizer()
                            ..onTap = () =>
                                _launchURL("https://bizforce360.com/terms"),
                          style: TextStyle(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                        const TextSpan(text: " and "),
                        TextSpan(
                          text: "Privacy Policy",
                          recognizer: TapGestureRecognizer()
                            ..onTap = () =>
                                _launchURL("https://bizforce360.com/privacy"),
                          style: TextStyle(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                        const TextSpan(text: "."),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}