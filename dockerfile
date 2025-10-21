# Use official Python image
FROM python:3.10-slim

# Set working directory
WORKDIR /app

# Copy all files
COPY . .

# Install dependencies if you have a requirements.txt file
RUN pip install -r requirements.txt || echo "No requirements.txt file"

# Expose app port (change if not 80)
EXPOSE 80

# Run the app
CMD ["python", "app.py"]
