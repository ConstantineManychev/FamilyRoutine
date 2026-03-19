import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { AuthenticationScreen } from './pages/AuthenticationScreen';
import { MainScreen } from './pages/MainScreen';

export const App = () => {
    return (
        <BrowserRouter>
            <Routes>
                <Route path="/auth" element={<AuthenticationScreen />} />
                <Route path="/*" element={<MainScreen />} />
            </Routes>
        </BrowserRouter>
    );
};