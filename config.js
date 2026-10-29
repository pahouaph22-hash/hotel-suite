// Connects both pages to the hotel's Supabase project. Empty both values to fall back to demo mode.
// The anon key is meant to be public: every write still goes through role-checked database functions.
window.HOTEL_CONFIG = {
  supabaseUrl: 'https://tnifwfakyfanqczmlkgi.supabase.co',
  supabaseAnonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRuaWZ3ZmFreWZhbnFjem1sa2dpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTMxNzQ3NjksImV4cCI6MjEwODc1MDc2OX0.a2-jeCXXq6wVrXgdtBqk7dKY-gAd8LkoOKBg9hwQfxU',
  // Optional: URL of the hotel's real payment QR image (from the bank's merchant app). Empty shows a sample.
  paymentQrImage: 'img/payment-qr.png'
};
