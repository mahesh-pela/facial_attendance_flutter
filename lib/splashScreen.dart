import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'businessSelector/apiSelectorByBusinessCode.dart';
import 'businessSelector/loginScreen.dart';
import 'dashboard/mainScreen.dart';
import 'manager/userProvider.dart';

class Splashscreen extends StatefulWidget {
  const Splashscreen({super.key});

  @override
  State<Splashscreen> createState() => _SplashscreenState();
}

class _SplashscreenState extends State<Splashscreen> {
  @override
  void initState() {
    super.initState();
    checkLogin();
  }

  void checkLogin() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    String apiURL = prefs.getString("apiURL") ?? "";
    String accessToken = prefs.getString("accessToken") ?? "";

    try {
      if (apiURL.isEmpty) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
              builder: (context) => ApiSelectorByBusinessCodeScreen()),
              (route) => false,
        );
      } else if (accessToken.isEmpty) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => LoginScreen()),
              (route) => false,
        );
      } else {
        await Provider.of<UserProvider>(context, listen: false).getConfig();

        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => MainScreen()),
              (route) => false,
        );
      }
    } catch (e) {
      // 👇 handle failed login/api call
      setState(() {
        debugPrint("error $e");

      });
    }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(height: 16),

            Text(
              "BizForce360",
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                color: Colors.blue.shade700,
                letterSpacing: 0.5,
              ),
            ),
            SizedBox(height: 8),


            SizedBox(height: 40),
            SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                color: Colors.blue.shade700,
                strokeWidth: 3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
