/// App configuration.
///
/// Fill in your Supabase project URL + anon key and your MQTT broker
/// credentials before building for production. The default MQTT broker
/// (broker.hivemq.com, port 1883) is the public test broker that matches
/// the ESP32 firmware's non-TLS path for quick local testing.
class AppConfig {
  // ---- Supabase ----
  static const String supabaseUrl = 'https://ybavbzfvuiibehewayad.supabase.co';
  static const String supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InliYXZiemZ2dWlpYmVoZXdheWFkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0MDUwMzgsImV4cCI6MjEwNzk4MTAzOH0.U1pw_8juHdNF3bLfo1WzJ-JRK8s0GQtyPRx6IWQpg0w';

  // ---- MQTT broker (App -> ESP32) ----
  // Use the broker that the ESP32 firmware connects to. For the public
  // fallback in the firmware this is broker.emqx.io:1883; for the TLS
  // primary it's your HiveMQ Cloud host on port 8883.
  static const String mqttBrokerHost = '15eb54ef85ce471890ec2a12019e88b4.s1.eu.hivemq.cloud';
  static const int mqttBrokerPort = 8883;
  static const String mqttUsername = 'CareCube12';
  static const String mqttPassword = 'CareCube@2006';

  // ---- Device ----
  static const String deviceId = 'carecube-001';
}
