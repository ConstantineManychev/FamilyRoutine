import { FormEvent, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { apiClient } from '../api/authService';

interface RegisterFormProps {
    onSwitchToLogin: () => void;
}

export const RegisterForm = ({ onSwitchToLogin }: RegisterFormProps) => {
    const { t } = useTranslation();
    const [firstName, setFirstName] = useState('');
    const [lastName, setLastName] = useState('');
    const [email, setEmail] = useState('');
    const [birthDate, setBirthDate] = useState('');
    const [password, setPassword] = useState('');
    const [registrationStatus, setRegistrationStatus] = useState<'idle' | 'success' | 'error'>('idle');

    const handleRegisterSubmit = async (event: FormEvent) => {
        event.preventDefault();
        setRegistrationStatus('idle');

        try {
            await apiClient.post('/api/auth/register', {
                firstName,
                lastName,
                email,
                birthDate,
                password
            });
            setRegistrationStatus('success');
        } catch (error) {
            setRegistrationStatus('error');
        }
    };

    if (registrationStatus === 'success') {
        return (
            <div className="flex flex-col items-center gap-4 text-center">
                <LanguageSelector />
                <form onSubmit={handleRegisterSubmit} className="flex flex-col gap-4">
                    <div className="flex items-center mb-2">
                    <button 
                            type="button"
                            onClick={onSwitchToLogin}
                            className="text-gray-400 hover:text-gray-600 transition-colors"
                            title="Back"
                        >
                            <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="15 19l-7-7 7-7" />
                            </svg>
                        </button>
                        <h2 className="text-2xl font-bold text-gray-800 ml-2">
                            {t('auth.registerTitle')}
                        </h2>
                    </div>
                <div className="w-16 h-16 bg-green-100 text-green-600 rounded-full flex items-center justify-center text-3xl mb-2">
                    ✓
                </div>
                <h2 className="text-2xl font-bold text-gray-800">{t('auth.registerSuccessTitle')}</h2>
                <p className="text-gray-600">{t('auth.registerSuccessMessage')}</p>
                <button 
                    onClick={onSwitchToLogin}
                    className="mt-4 bg-blue-600 text-white px-6 py-2 rounded-lg hover:bg-blue-700 transition-colors"
                >
                    {t('auth.returnToLogin')}
                </button>
            </div>
        );
    }

    return (
        <form onSubmit={handleRegisterSubmit} className="flex flex-col gap-5">
            <h2 className="text-3xl font-bold text-center text-gray-800 tracking-tight">
                {t('auth.registerTitle')}
            </h2>
            
            {registrationStatus === 'error' && (
                <div className="bg-red-50 text-red-600 p-3 rounded-lg text-sm text-center">
                    {t('auth.registerError')}
                </div>
            )}

            <div className="flex gap-3">
                <input
                    type="text"
                    placeholder={t('auth.firstNamePlaceholder')}
                    value={firstName}
                    onChange={(e) => setFirstName(e.target.value)}
                    className="border border-gray-300 p-3 rounded-lg w-full focus:outline-none focus:ring-2 focus:ring-blue-500 transition-shadow"
                    required
                />
                <input
                    type="text"
                    placeholder={t('auth.lastNamePlaceholder')}
                    value={lastName}
                    onChange={(e) => setLastName(e.target.value)}
                    className="border border-gray-300 p-3 rounded-lg w-full focus:outline-none focus:ring-2 focus:ring-blue-500 transition-shadow"
                    required
                />
            </div>
            
            <input
                type="email"
                placeholder={t('auth.emailPlaceholder')}
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 transition-shadow"
                required
            />
            
            <input
                type="date"
                value={birthDate}
                onChange={(e) => setBirthDate(e.target.value)}
                className="border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 text-gray-700 transition-shadow"
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

            <button 
                type="submit" 
                className="bg-green-600 text-white p-3 rounded-lg hover:bg-green-700 transition-colors font-semibold shadow-md"
            >
                {t('auth.registerSubmit')}
            </button>
            
            <button 
                type="button" 
                onClick={onSwitchToLogin} 
                className="text-blue-500 hover:text-blue-700 hover:underline text-sm font-medium transition-colors"
            >
                {t('auth.switchToLogin')}
            </button>
        </form>
    );
};