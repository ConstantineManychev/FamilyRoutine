import { useState } from 'react';
import { LoginForm } from '../components/LoginForm';
import { RegisterForm } from '../components/RegisterForm';
import { LanguageSelector } from '../components/LanguageSelector';

type AuthenticationMode = 'login' | 'register';

export const AuthenticationScreen = () => {
    const [currentMode, setCurrentMode] = useState<AuthenticationMode>('login');

    const handleSwitchMode = (mode: AuthenticationMode) => {
        setCurrentMode(mode);
    };

    return (
        <div className="min-h-screen w-full flex items-center justify-center bg-blue-500 bg-[url('/src/assets/background.jpg')] bg-cover bg-center bg-no-repeat relative">
            <div className="absolute inset-0 bg-black/30 backdrop-blur-sm z-0"></div>
            
            <div className="absolute top-4 right-4 z-50">
                <LanguageSelector />
            </div>

            <div className="bg-white/95 backdrop-blur-md p-8 md:p-10 rounded-2xl shadow-2xl w-full max-w-md relative z-10 mx-4 border border-white/20">
                {currentMode === 'login' ? (
                    <LoginForm onSwitchToRegister={() => handleSwitchMode('register')} />
                ) : (
                    <RegisterForm onSwitchToLogin={() => handleSwitchMode('login')} />
                )}
            </div>
        </div>
    );
};