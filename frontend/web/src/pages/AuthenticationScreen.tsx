import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { LoginForm } from '../components/LoginForm';
import { RegisterForm } from '../components/RegisterForm';

type AuthenticationMode = 'login' | 'register';

export const AuthenticationScreen = () => {
    const { i18n } = useTranslation();
    const [currentMode, setCurrentMode] = useState<AuthenticationMode>('login');

    const handleSwitchMode = (mode: AuthenticationMode) => {
        setCurrentMode(mode);
    };

    const handleLanguageChange = (languageCode: string) => {
        i18n.changeLanguage(languageCode);
    };

    return (
        <div className="min-h-screen w-full flex items-center justify-center bg-blue-500 bg-[url('/src/assets/background.jpg')] bg-cover bg-center bg-no-repeat relative">
            
            <div className="absolute inset-0 bg-black/30 backdrop-blur-sm"></div>

            <div className="absolute top-4 right-4 z-20 flex gap-2">
                <button 
                    onClick={() => handleLanguageChange('en')}
                    className={`px-3 py-1 rounded text-sm font-semibold transition-colors ${i18n.language === 'en' ? 'bg-white text-blue-600' : 'bg-white/20 text-white hover:bg-white/40'}`}
                >
                    EN
                </button>
                <button 
                    onClick={() => handleLanguageChange('ru')}
                    className={`px-3 py-1 rounded text-sm font-semibold transition-colors ${i18n.language === 'ru' ? 'bg-white text-blue-600' : 'bg-white/20 text-white hover:bg-white/40'}`}
                >
                    RU
                </button>
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