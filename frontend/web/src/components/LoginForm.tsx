import { FormEvent, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { apiClient } from '../api/authService';

interface LoginFormProps {
    onSwitchToRegister: () => void;
}

export const LoginForm = ({ onSwitchToRegister }: LoginFormProps) => {
    const { t } = useTranslation();
    const [email, setEmail] = useState('');
    const [password, setPassword] = useState('');
    const [errorMessage, setErrorMessage] = useState('');

    const handleLoginSubmit = async (event: FormEvent) => {
        event.preventDefault();
        setErrorMessage('');

        try {
            await apiClient.post('/api/auth/login', { email, password });
        } catch (error) {
            setErrorMessage(t('auth.loginError'));
        }
    };

    return (
        <form onSubmit={handleLoginSubmit} className="flex flex-col gap-5">
            <h2 className="text-3xl font-bold text-center text-gray-800 tracking-tight">
                {t('auth.loginTitle')}
            </h2>
            
            {errorMessage && (
                <div className="bg-red-50 text-red-600 p-3 rounded-lg text-sm text-center">
                    {errorMessage}
                </div>
            )}

            <div className="flex flex-col gap-4">
                <LanguageSelector />
                <form onSubmit={handleLoginSubmit} className="flex flex-col gap-5">
                    <h2 className="text-3xl font-bold text-center text-gray-800 tracking-tight">
                        {t('auth.loginTitle')}
                    </h2>
                <input
                    type="email"
                    placeholder={t('auth.emailPlaceholder')}
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    className="border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 transition-shadow"
                    required
                />
                <input
                    type="password"
                    placeholder={t('auth.passwordPlaceholder')}
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    className="border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 transition-shadow"
                    required
                />
            </div>

            <button 
                type="submit" 
                className="bg-blue-600 text-white p-3 rounded-lg hover:bg-blue-700 transition-colors font-semibold shadow-md"
            >
                {t('auth.loginSubmit')}
            </button>
            
            <button 
                type="button" 
                onClick={onSwitchToRegister} 
                className="text-blue-500 hover:text-blue-700 hover:underline text-sm font-medium transition-colors"
            >
                {t('auth.switchToRegister')}
            </button>
        </form>
    );
};