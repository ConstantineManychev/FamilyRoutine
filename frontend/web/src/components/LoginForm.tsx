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
        <form onSubmit={handleLoginSubmit} className="flex flex-col gap-6 w-full">
            <h2 className="text-3xl font-bold text-center text-gray-800">
                {t('auth.loginTitle')}
            </h2>
            
            {errorMessage && (
                <div className="bg-red-50 text-red-600 p-3 rounded-lg text-sm text-center">
                    {errorMessage}
                </div>
            )}

            <div className="flex flex-col gap-4">
                <div className="flex flex-col gap-1">
                    <label className="text-sm font-semibold text-gray-700">{t('auth.emailLabel')}</label>
                    <input
                        type="email"
                        value={email}
                        onChange={(e) => setEmail(e.target.value)}
                        className="border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
                        required
                    />
                </div>
                <div className="flex flex-col gap-1">
                    <label className="text-sm font-semibold text-gray-700">{t('auth.passwordLabel')}</label>
                    <input
                        type="password"
                        value={password}
                        onChange={(e) => setPassword(e.target.value)}
                        className="border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
                        required
                    />
                </div>
            </div>

            <div className="flex flex-row gap-3 mt-2">
                <button 
                    type="submit" 
                    className="flex-1 bg-blue-600 text-white p-3 rounded-lg hover:bg-blue-700 font-semibold transition-colors"
                >
                    {t('auth.loginSubmit')}
                </button>
                <button 
                    type="button" 
                    onClick={onSwitchToRegister} 
                    className="flex-1 bg-gray-100 text-gray-800 p-3 rounded-lg hover:bg-gray-200 font-semibold transition-colors border border-gray-200"
                >
                    {t('auth.switchToRegister')}
                </button>
            </div>
        </form>
    );
};