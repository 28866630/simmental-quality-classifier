# Prototype – Simmental Quality Classifier Application

This folder contains the **prototype implementation** that demonstrates the practical use of the trained models in a real-world workflow.  
The prototype connects a **Flask backend** with a **Flutter frontend**, running inference with a TensorFlow Lite model.

## Contents
- `backend/` – Flask server for preprocessing and inference.  
- `frontend/` – Flutter Web application for user interaction.  
- `models/` – TensorFlow Lite (`.tflite`) model used for deployment.  
- `tests/` – Unit and integration tests for backend and frontend.  

## Usage

### Backend (Flask)

cd backend
pip install -r requirements.txt
python app.py 

### Frontend
cd frontend
flutter pub get
flutter run -d chrome

## Prototype steps
Upload an image of a cow through the web app.
The backend performs preprocessing and inference, returning a classification result (Good or Bad).

## Notes
This prototype is for demonstration purposes only and is not production-ready.
It reuses the .tflite model exported from the research notebooks.
