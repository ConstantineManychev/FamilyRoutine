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
                first_name: firstName,
                last_name: lastName,
                email,
                birth_date: birthDate,
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
                <div className="w-16 h-16 bg-green-100 text-green-600 rounded-full flex items-center justify-center text-3xl mb-2">✓</div>
                <h2 className="text-2xl font-bold text-gray-800">{t('auth.registerSuccessTitle')}</h2>
                <p className="text-gray-600">{t('auth.registerSuccessMessage')}</p>
                <button onClick={onSwitchToLogin} className="mt-4 bg-blue-600 text-white px-6 py-2 rounded-lg hover:bg-blue-700 font-semibold">
                    {t('auth.returnToLogin')}
                </button>
            </div>
        );
    }

    return (
        <form onSubmit={handleRegisterSubmit} className="flex flex-col gap-6 w-full">
            <h2 className="text-3xl font-bold text-center text-gray-800">
                {t('auth.registerTitle')}
            </h2>

            {registrationStatus === 'error' && (
                <div className="bg-red-50 text-red-600 p-3 rounded-lg text-sm text-center">
                    {t('auth.registerError')}
                </div>
            )}

            <div className="flex flex-col gap-4">
                <div className="flex gap-3">
                    <div className="flex flex-col gap-1 w-full">
                        <label className="text-sm font-semibold text-gray-700">{t('auth.firstNameLabel')}</label>
                        <input type="text" value={firstName} onChange={(e) => setFirstName(e.target.value)} className="border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 w-full" required />
                    </div>
                    <div className="flex flex-col gap-1 w-full">
                        <label className="text-sm font-semibold text-gray-700">{t('auth.lastNameLabel')}</label>
                        <input type="text" value={lastName} onChange={(e) => setLastName(e.target.value)} className="border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 w-full" required />
                    </div>
                </div>
                
                <div className="flex flex-col gap-1">
                    <label className="text-sm font-semibold text-gray-700">{t('auth.emailLabel')}</label>
                    <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} className="border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500" required />
                </div>
                
                <div className="flex flex-col gap-1">
                    <label className="text-sm font-semibold text-gray-700">{t('auth.birthDateLabel')}</label>
                    <input type="date" value={birthDate} onChange={(e) => setBirthDate(e.target.value)} className="border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500" required />
                </div>
                
                <div className="flex flex-col gap-1">
                    <label className="text-sm font-semibold text-gray-700">{t('auth.passwordLabel')}</label>
                    <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} className="border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500" required />
                </div>
            </div>

            <div className="flex flex-row gap-3 mt-2">
                <button type="submit" className="flex-1 bg-green-600 text-white p-3 rounded-lg hover:bg-green-700 font-semibold transition-colors">
                    {t('auth.registerSubmit')}
                </button>
                <button type="button" onClick={onSwitchToLogin} className="flex-1 bg-gray-100 text-gray-800 p-3 rounded-lg hover:bg-gray-200 font-semibold transition-colors border border-gray-200">
                    {t('auth.switchToLogin')}
                </button>
            </div>
        </form>
    );
};