import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { AuthenticationScreen } from './pages/AuthenticationScreen';

function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/auth" element={<AuthenticationScreen />} />
        
        <Route path="/" element={<Navigate to="/auth" replace />} />
        
      </Routes>
    </BrowserRouter>
  );
}

export default App;