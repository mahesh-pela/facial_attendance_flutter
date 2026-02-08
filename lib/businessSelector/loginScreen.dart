import 'package:dio/dio.dart';
import 'package:face_attendance/splashScreen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../manager/dioErrorManager.dart';
import '../manager/mydio.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => LoginScreenState();
}

class LoginScreenState extends State<LoginScreen> {
  // Controllers for text input fields
  final TextEditingController numberController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final FocusNode _numberFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();

  // State variables
  bool isLoading = false;
  bool passwordVisible = false;

  // Form key for validation
  final GlobalKey<FormState> formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    // Uncomment for testing
    // numberController.text = "9812345678";
    // passwordController.text = "123456";
  }

  @override
  void dispose() {
    numberController.dispose();
    passwordController.dispose();
    _numberFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  // Login function with improved error handling
  Future<void> performLogin() async {
    // Unfocus to dismiss keyboard
    _numberFocusNode.unfocus();
    _passwordFocusNode.unfocus();

    // Validate form before proceeding
    if (!formKey.currentState!.validate()) {
      return;
    }

    if (mounted) {
      setState(() {
        isLoading = true;
      });
    }

    try {
      final Map<String, dynamic> loginData = {
        "number": numberController.text.trim(),
        "password": passwordController.text
      };

      final response = await (await MyDio().getDio())
          .post("/users/login", data: loginData);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'accessToken', response.data["accessToken"].toString());

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const Splashscreen()),
              (route) => false,
        );
      }
    } on DioException catch (e) {
      dioErrorManager(e);
    } catch (e) {
      debugPrint("Login error: $e");
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  // Function to navigate to change server screen
  Future<void> changeApiServer() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove("apiURL");

    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const Splashscreen()),
            (route) => false,
      );
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
            child: Form(
              key: formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 20),

                  // Logo and branding section
                  _buildLogoSection(isDark),

                  const SizedBox(height: 48),

                  // Input fields section
                  _buildInputSection(isDark, colorScheme),

                  const SizedBox(height: 32),

                  // Login button
                  _buildLoginButton(isDark, colorScheme),

                  const SizedBox(height: 24),

                  // Terms and Privacy Policy
                  _buildTermsSection(isDark, colorScheme),

                  const SizedBox(height: 32),

                  // Server settings section
                  _buildServerSettingsSection(isDark, colorScheme),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Logo and branding section widget
  Widget _buildLogoSection(bool isDark) {
    return Column(
      children: [
        // Company logo
        Container(
          height: 100.0,
          width: 100.0,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24.0),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 20.0,
                offset: const Offset(0, 8),
              ),
              BoxShadow(
                color: Colors.black.withOpacity(0.03),
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

        const SizedBox(height: 32.0),

        // Welcome text
        Text(
          'Welcome Back',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 28.0,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : Colors.grey[900],
            letterSpacing: -0.5,
          ),
        ),

        const SizedBox(height: 12.0),

        Text(
          'Sign in to continue to BizForce360',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16.0,
            color: isDark ? Colors.grey[400] : Colors.grey[600],
            height: 1.5,
          ),
        ),
      ],
    );
  }

  // Input fields section widget
  Widget _buildInputSection(bool isDark, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Mobile number field
        TextFormField(
          controller: numberController,
          focusNode: _numberFocusNode,
          enabled: !isLoading,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.next,
          onFieldSubmitted: (_) {
            _passwordFocusNode.requestFocus();
          },
          style: TextStyle(
            fontSize: 16.0,
            fontWeight: FontWeight.w500,
            color: isDark ? Colors.white : Colors.grey[900],
          ),
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return 'Please enter your mobile number';
            }
            if (value.trim().length < 10) {
              return 'Please enter a valid mobile number';
            }
            return null;
          },
          decoration: InputDecoration(
            labelText: 'Mobile Number',
            hintText: 'Enter your mobile number',
            labelStyle: TextStyle(
              color: isDark ? Colors.grey[400] : Colors.grey[600],
            ),
            hintStyle: TextStyle(
              color: isDark ? Colors.grey[600] : Colors.grey[400],
            ),
            prefixIcon: Icon(
              Icons.phone_outlined,
              color: colorScheme.primary,
              size: 22,
            ),
            filled: true,
            fillColor: isDark ? Colors.grey[850] : Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16.0),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16.0),
              borderSide: BorderSide(
                color: isDark ? Colors.grey[700]! : Colors.grey[200]!,
                width: 1.5,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16.0),
              borderSide: BorderSide(
                color: colorScheme.primary,
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

        const SizedBox(height: 20.0),

        // Password field
        TextFormField(
          controller: passwordController,
          focusNode: _passwordFocusNode,
          enabled: !isLoading,
          obscureText: !passwordVisible,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) => performLogin(),
          style: TextStyle(
            fontSize: 16.0,
            fontWeight: FontWeight.w500,
            color: isDark ? Colors.white : Colors.grey[900],
          ),
          validator: (value) {
            if (value == null || value.isEmpty) {
              return 'Please enter your password';
            }
            if (value.length < 6) {
              return 'Password must be at least 6 characters';
            }
            return null;
          },
          decoration: InputDecoration(
            labelText: 'Password',
            hintText: 'Enter your password',
            labelStyle: TextStyle(
              color: isDark ? Colors.grey[400] : Colors.grey[600],
            ),
            hintStyle: TextStyle(
              color: isDark ? Colors.grey[600] : Colors.grey[400],
            ),
            prefixIcon: Icon(
              Icons.lock_outline,
              color: colorScheme.primary,
              size: 22,
            ),
            suffixIcon: IconButton(
              icon: Icon(
                passwordVisible
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                color: isDark ? Colors.grey[400] : Colors.grey[600],
                size: 22,
              ),
              onPressed: () {
                setState(() {
                  passwordVisible = !passwordVisible;
                });
              },
            ),
            filled: true,
            fillColor: isDark ? Colors.grey[850] : Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16.0),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16.0),
              borderSide: BorderSide(
                color: isDark ? Colors.grey[700]! : Colors.grey[200]!,
                width: 1.5,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16.0),
              borderSide: BorderSide(
                color: colorScheme.primary,
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
      ],
    );
  }

  // Login button widget
  Widget _buildLoginButton(bool isDark, ColorScheme colorScheme) {
    return SizedBox(
      height: 56.0,
      child: ElevatedButton(
        onPressed: isLoading ? null : performLogin,
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: isDark ? Colors.grey[800] : Colors.grey[300],
          elevation: isLoading ? 0 : 2.0,
          shadowColor: colorScheme.primary.withOpacity(0.3),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16.0),
          ),
        ),
        child: isLoading
            ? const SizedBox(
          height: 24.0,
          width: 24.0,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        )
            : Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(
              Icons.login_outlined,
              size: 20.0,
              color: Colors.white,
            ),
            SizedBox(width: 10.0),
            Text(
              'Sign In',
              style: TextStyle(
                fontSize: 16.0,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Terms and Privacy Policy section
  Widget _buildTermsSection(bool isDark, ColorScheme colorScheme) {
    return Padding(
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
                ..onTap = () => _launchURL("https://bizforce360.com/terms"),
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
                ..onTap = () => _launchURL("https://bizforce360.com/privacy"),
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
    );
  }

  // Server settings section widget
  Widget _buildServerSettingsSection(bool isDark, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(20.0),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[850]?.withOpacity(0.3) : Colors.grey[100],
        borderRadius: BorderRadius.circular(16.0),
        border: Border.all(
          color: isDark ? Colors.grey[800]! : Colors.grey[200]!,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.settings_outlined,
                size: 20.0,
                color: isDark ? Colors.grey[400] : Colors.grey[700],
              ),
              const SizedBox(width: 10.0),
              Text(
                'Server Configuration',
                style: TextStyle(
                  fontSize: 15.0,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.grey[300] : Colors.grey[800],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12.0),
          Text(
            'Having trouble connecting or need to change server?',
            style: TextStyle(
              fontSize: 13.0,
              color: isDark ? Colors.grey[500] : Colors.grey[600],
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16.0),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: isLoading ? null : changeApiServer,
              icon: Icon(
                Icons.dns_outlined,
                size: 18.0,
                color: colorScheme.primary,
              ),
              label: Text(
                'Change Server',
                style: TextStyle(
                  fontSize: 14.0,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.primary,
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: colorScheme.primary,
                side: BorderSide(
                  color: isDark ? Colors.grey[700]! : Colors.grey[300]!,
                  width: 1.5,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12.0),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14.0),
              ),
            ),
          ),
        ],
      ),
    );
  }
}