import requests

SERVER_IP = "172.17.246.182"  # CHANGE THIS to your Mac's local IP
PORT = 5001

url = f"http://{SERVER_IP}:{PORT}/api/techniques"

try:
    response = requests.get(url, timeout=5)

    print("Status code:", response.status_code)
    print("Response:")

    print(response.json())

except requests.exceptions.ConnectionError:
    print("❌ Could not connect to the Flask server.")
    print("Check that:")
    print("  - Both laptops are on the same Wi-Fi")
    print("  - Flask is running with host='0.0.0.0'")
    print("  - The IP address is correct")
    print("  - Port 5000 is not blocked")

except requests.exceptions.Timeout:
    print("❌ Connection timed out.")

except Exception as e:
    print("❌ Error:", e)