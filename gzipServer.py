import http.server
import gzip
import io
from http import HTTPStatus

class GzipChunkedHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # Response data to compress
        response_text = "Hello, this is a compressed and chunked response!"

        # Compress the response using gzip
        compressed_buffer = io.BytesIO()
        with gzip.GzipFile(fileobj=compressed_buffer, mode='wb') as gzip_file:
            gzip_file.write(response_text.encode('utf-8'))
        compressed_data = compressed_buffer.getvalue()

        # Send HTTP headers
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Encoding", "gzip")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        # Send the chunked response
        chunk_size = 16  # Customize the size of each chunk
        print(f"len of compressed_data: {len(compressed_data)}")
        for i in range(0, len(compressed_data), chunk_size):
            chunk = compressed_data[i:i + chunk_size]
            self.wfile.write(f"{len(chunk):X}\r\n".encode('utf-8'))
            self.wfile.write(chunk)
            self.wfile.write(b"\r\n")
        self.wfile.write(b"0\r\n\r\n")  # End of chunked encoding

if __name__ == "__main__":
    server_address = ('', 8000)  # Serve on localhost:8000
    httpd = http.server.HTTPServer(server_address, GzipChunkedHandler)
    print("Serving on http://localhost:8000...")
    httpd.serve_forever()
