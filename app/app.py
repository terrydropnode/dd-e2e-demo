import os
import subprocess
import urllib.request
from flask import Flask, request, jsonify
import boto3
import yaml  # Imported to trigger SCA reachability

app = Flask(__name__)

@app.route('/health', methods=['GET'])
def health():
    return jsonify({"status": "healthy"}), 200

# VULNERABILITY 1: Command Injection (Triggers SAST, IAST, ASM, and eBPF CWS)
@app.route('/api/v1/diagnostics', methods=['GET'])
def diagnostics():
    target = request.args.get('target', '8.8.8.8')
    # Intentional insecure subprocess call with shell=True
    cmd = f"ping -c 1 {target}"
    try:
        output = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT)
        return jsonify({"target": target, "output": output.decode('utf-8')})
    except subprocess.CalledProcessError as e:
        return jsonify({"error": e.output.decode('utf-8')}), 500

# VULNERABILITY 2: SSRF / Credential Harvest (Triggers ASM SSRF & IMDS Theft)
@app.route('/api/v1/fetch-invoice', methods=['POST'])
def fetch_invoice():
    url = request.json.get('url', 'https://example.com')
    try:
        # Can be pointed to http://169.254.169.254/latest/meta-data/iam/security-credentials/
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=3) as response:
            data = response.read().decode('utf-8')
        return jsonify({"url": url, "content": data[:500]})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

# VULNERABILITY 3: Unsafe YAML Deserialization (Triggers SCA & SAST)
@app.route('/api/v1/parse-config', methods=['POST'])
def parse_config():
    raw_yaml = request.data.decode('utf-8')
    # Using unsafe yaml.load instead of safe_load
    parsed = yaml.load(raw_yaml, Loader=yaml.Loader)
    return jsonify({"parsed": str(parsed)})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
