import 'package:face_attendance/businessSelector/apiSelectorByBusinessCode.dart';
import 'package:face_attendance/dashboard/addUser.dart';
import 'package:face_attendance/dashboard/markAttendance.dart';
import 'package:face_attendance/manager/userProvider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  @override
  Widget build(BuildContext context) {
    final userProvider = Provider.of<UserProvider>(context, listen: false);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.blue.shade900,
              Colors.blue.shade800,
              Colors.blue.shade700,
            ],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [

          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Face Recognition",
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    "Secure Attendance System",
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),

              PopupMenuButton<String>(
                offset: Offset(0, 50),
                onSelected: (value) async{
                  if (value == 'logout') {
                    final SharedPreferences prefs = await SharedPreferences.getInstance();
                    prefs.clear();
                    Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (context)=>ApiSelectorByBusinessCodeScreen()), (route)=>false);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem<String>(
                    enabled: false,
                    child: Text(
                      userProvider.userData["name"],
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
                    ),
                  ),

                  PopupMenuDivider(),

                  PopupMenuItem<String>(
                    value: 'logout',
                    child: Row(
                      children: [
                        Icon(Icons.logout, size: 18),
                        SizedBox(width: 8),
                        Text("Logout"),
                      ],
                    ),
                  ),
                ],
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white30, width: 1.5),
                  ),
                  child: Icon(
                    Icons.person_outline,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
            ],
          ),
        ),



          SizedBox(height: 25),

              // Hero Section
              Expanded(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Column(
                      children: [
                        // Welcome Card
                        Container(
                          width: double.infinity,
                          padding: EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 20,
                                offset: Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Column(
                            children: [
                              Container(
                                width: 80,
                                height: 80,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: LinearGradient(
                                    colors: [
                                      Colors.blue.shade600,
                                      Colors.blue.shade800,
                                    ],
                                  ),
                                ),
                                child: Icon(
                                  Icons.face_retouching_natural,
                                  color: Colors.white,
                                  size: 40,
                                ),
                              ),
                              SizedBox(height: 20),
                              Text(
                                "Welcome to Face Attendance",
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey.shade800,
                                ),
                              ),
                              SizedBox(height: 12),
                              Text(
                                "Use facial recognition for secure and efficient attendance marking",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.grey.shade600,
                                  height: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),

                        SizedBox(height: 20),

                        // Actions Grid
                        Column(
                          children: [
                            // Row 1
                            Row(
                              children: [
                                Expanded(
                                  child: _buildActionCard(
                                    title: "Mark Attendance",
                                    subtitle: "Verify identity and log attendance",
                                    icon: Icons.fingerprint,
                                    color: Colors.green,
                                    iconBackground: Colors.green.shade50,
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) => MarkAttendance(),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                SizedBox(width: 16),
                                Expanded(
                                  child: _buildActionCard(
                                    title: "Register User",
                                    subtitle: "Add new person to system",
                                    icon: Icons.person_add,
                                    color: Colors.blue,
                                    iconBackground: Colors.blue.shade50,
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) => RegisterUser(),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),

                            SizedBox(height: 16),

                            // Row 2 (Additional options if needed)
                            // Row(
                            //   children: [
                            //     Expanded(
                            //       child: _buildActionCard(
                            //         title: "Attendance Report",
                            //         subtitle: "View attendance history",
                            //         icon: Icons.bar_chart,
                            //         color: Colors.orange,
                            //         iconBackground: Colors.orange.shade50,
                            //         onTap: () {
                            //           // Add report screen navigation
                            //         },
                            //       ),
                            //     ),
                            //     SizedBox(width: 16),
                            //     Expanded(
                            //       child: _buildActionCard(
                            //         title: "Settings",
                            //         subtitle: "Configure system settings",
                            //         icon: Icons.settings,
                            //         color: Colors.purple,
                            //         iconBackground: Colors.purple.shade50,
                            //         onTap: () {
                            //           // Add settings screen navigation
                            //         },
                            //       ),
                            //     ),
                            //   ],
                            // ),
                          ],
                        ),

                        SizedBox(height: 40),

                        // // Stats or Info Section
                        // Container(
                        //   padding: EdgeInsets.all(20),
                        //   decoration: BoxDecoration(
                        //     color: Colors.white.withOpacity(0.1),
                        //     borderRadius: BorderRadius.circular(16),
                        //     border: Border.all(color: Colors.white30),
                        //   ),
                        //   child: Row(
                        //     children: [
                        //       Container(
                        //         padding: EdgeInsets.all(12),
                        //         decoration: BoxDecoration(
                        //           shape: BoxShape.circle,
                        //           color: Colors.white.withOpacity(0.2),
                        //         ),
                        //         child: Icon(
                        //           Icons.security,
                        //           color: Colors.white,
                        //           size: 24,
                        //         ),
                        //       ),
                        //       SizedBox(width: 16),
                        //       Expanded(
                        //         child: Column(
                        //           crossAxisAlignment: CrossAxisAlignment.start,
                        //           children: [
                        //             Text(
                        //               "Security Features",
                        //               style: TextStyle(
                        //                 color: Colors.white,
                        //                 fontWeight: FontWeight.w600,
                        //                 fontSize: 14,
                        //               ),
                        //             ),
                        //             SizedBox(height: 4),
                        //             Text(
                        //               "Live face detection • Anti-spoofing • Encrypted data",
                        //               style: TextStyle(
                        //                 color: Colors.white70,
                        //                 fontSize: 12,
                        //               ),
                        //             ),
                        //           ],
                        //         ),
                        //       ),
                        //     ],
                        //   ),
                        // ),
                        //
                        // SizedBox(height: 60),

                        // Version Info
                        // Text(
                        //   "Version 2.1.0 • Secure System",
                        //   style: TextStyle(
                        //     color: Colors.white54,
                        //     fontSize: 12,
                        //   ),
                        // ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required Color iconBackground,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      elevation: 4,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade100),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: iconBackground,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: color,
                  size: 28,
                ),
              ),
              SizedBox(height: 16),
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade800,
                ),
              ),
              SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                ),
              ),
              SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.arrow_forward,
                    color: color,
                    size: 16,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}