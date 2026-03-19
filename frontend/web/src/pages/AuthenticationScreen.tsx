import { useState } from 'react';
import { LoginForm } from '../components/LoginForm';
import { RegisterForm } from '../components/RegisterForm';
import { LanguageSelector } from '../components/LanguageSelector';

type AuthMode = 'login' | 'register';

export const AuthenticationScreen = () => {
    const [authMode, setAuthMode] = useState<AuthMode>('login');

    return (
        <div className="min-h-screen w-screen relative flex items-center justify-center bg-blue-500 bg-[url('/src/assets/background.jpg')] bg-cover bg-center bg-no-repeat">
            <div className="absolute inset-0 bg-black/30 backdrop-blur-sm z-0" />
            
            <div className="absolute top-4 left-4 z-50">
                <LanguageSelector />
            </div>

            <div className="relative z-10 w-full max-w-md bg-white/95 backdrop-blur-md p-8 md:p-10 rounded-2xl shadow-2xl mx-4 border border-white/20">
                {authMode === 'login' ? (
                    <LoginForm onSwitchMode={() => setAuthMode('register')} />
                ) : (
                    <RegisterForm onSwitchMode={() => setAuthMode('login')} />
                )}
            </div>
        </div>
    );
};