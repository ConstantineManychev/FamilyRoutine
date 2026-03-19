import { FormEvent, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { apiClient } from '../api/authService';

interface LoginFormProps {
    onSwitchMode: () => void;
}

export const LoginForm = ({ onSwitchMode }: LoginFormProps) => {
    const { t } = useTranslation();
    const [email, setEmail] = useState('');
    const [pwd, setPwd] = useState('');
    const [errMsg, setErrMsg] = useState('');

    const handleSubmit = async (e: FormEvent) => {
        e.preventDefault();
        setErrMsg('');

        try {
            await apiClient.post('/api/auth/login', { email, password: pwd });
        } catch {
            setErrMsg(t('auth.loginError'));
        }
    };

    return (
        <form onSubmit={handleSubmit} className="flex flex-col gap-6 w-full">
            <h2 className="text-3xl font-bold text-center text-gray-800">
                {t('auth.loginTitle')}
            </h2>
            
            {errMsg && (
                <div className="bg-red-50 text-red-600 p-3 rounded-lg text-sm text-center">
                    {errMsg}
                </div>
            )}

            <div className="flex flex-col gap-4">
                <div className="flex flex-col gap-1.5 w-full">
                    <label className="text-sm font-semibold text-gray-700">
                        {t('auth.emailLabel')}
                    </label>
                    <input
                        type="email"
                        value={email}
                        onChange={(e) => setEmail(e.target.value)}
                        className="w-full border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
                        required
                    />
                </div>
                
                <div className="flex flex-col gap-1.5 w-full">
                    <label className="text-sm font-semibold text-gray-700">
                        {t('auth.passwordLabel')}
                    </label>
                    <input
                        type="password"
                        value={pwd}
                        onChange={(e) => setPwd(e.target.value)}
                        className="w-full border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
                        required
                    />
                </div>
            </div>

            <div className="flex flex-col gap-3 mt-2">
                <button 
                    type="submit" 
                    className="w-full bg-blue-600 text-white p-3 rounded-lg hover:bg-blue-700 font-semibold transition-colors shadow-md"
                >
                    {t('auth.loginSubmit')}
                </button>
                <button 
                    type="button" 
                    onClick={onSwitchMode} 
                    className="w-full bg-transparent text-gray-600 p-3 rounded-lg hover:bg-gray-100 font-semibold transition-colors"
                >
                    {t('auth.switchToRegister')}
                </button>
            </div>
        </form>
    );
};