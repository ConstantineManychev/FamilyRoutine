import { FormEvent, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { apiClient } from '../api/authService';

interface RegisterFormProps {
    onSwitchMode: () => void;
}

export const RegisterForm = ({ onSwitchMode }: RegisterFormProps) => {
    const { t } = useTranslation();
    const [fName, setFName] = useState('');
    const [lName, setLName] = useState('');
    const [email, setEmail] = useState('');
    const [dob, setDob] = useState('');
    const [pwd, setPwd] = useState('');
    const [regState, setRegState] = useState<'idle' | 'success' | 'error'>('idle');

    const handleSubmit = async (e: FormEvent) => {
        e.preventDefault();
        setRegState('idle');

        try {
            await apiClient.post('/api/auth/register', {
                first_name: fName,
                last_name: lName,
                email,
                birth_date: dob,
                password: pwd
            });
            setRegState('success');
        } catch {
            setRegState('error');
        }
    };

    if (regState === 'success') {
        return (
            <div className="flex flex-col items-center gap-4 text-center">
                <div className="w-16 h-16 bg-green-100 text-green-600 rounded-full flex items-center justify-center text-3xl mb-2">✓</div>
                <h2 className="text-2xl font-bold text-gray-800">{t('auth.registerSuccessTitle')}</h2>
                <p className="text-gray-600">{t('auth.registerSuccessMessage')}</p>
                <button onClick={onSwitchMode} className="mt-4 bg-blue-600 text-white px-6 py-2 rounded-lg hover:bg-blue-700 font-semibold">
                    {t('auth.returnToLogin')}
                </button>
            </div>
        );
    }

    return (
        <form onSubmit={handleSubmit} className="flex flex-col gap-6 w-full">
            <h2 className="text-3xl font-bold text-center text-gray-800">
                {t('auth.registerTitle')}
            </h2>

            {regState === 'error' && (
                <div className="bg-red-50 text-red-600 p-3 rounded-lg text-sm text-center">
                    {t('auth.registerError')}
                </div>
            )}

            <div className="flex flex-col gap-4">
                <div className="flex gap-4 w-full">
                    <div className="flex flex-col gap-1.5 flex-1">
                        <label className="text-sm font-semibold text-gray-700">{t('auth.firstNameLabel')}</label>
                        <input type="text" value={fName} onChange={(e) => setFName(e.target.value)} className="w-full border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500" required />
                    </div>
                    <div className="flex flex-col gap-1.5 flex-1">
                        <label className="text-sm font-semibold text-gray-700">{t('auth.lastNameLabel')}</label>
                        <input type="text" value={lName} onChange={(e) => setLName(e.target.value)} className="w-full border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500" required />
                    </div>
                </div>

                <div className="flex flex-col gap-1.5 w-full">
                    <label className="text-sm font-semibold text-gray-700">{t('auth.emailLabel')}</label>
                    <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} className="w-full border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500" required />
                </div>
                
                <div className="flex flex-col gap-1.5 w-full">
                    <label className="text-sm font-semibold text-gray-700">{t('auth.birthDateLabel')}</label>
                    <input type="date" value={dob} onChange={(e) => setDob(e.target.value)} className="w-full border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 text-gray-700" required />
                </div>
                
                <div className="flex flex-col gap-1.5 w-full">
                    <label className="text-sm font-semibold text-gray-700">{t('auth.passwordLabel')}</label>
                    <input type="password" value={pwd} onChange={(e) => setPwd(e.target.value)} className="w-full border border-gray-300 p-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500" required />
                </div>
            </div>

            <div className="flex flex-col gap-3 mt-2">
                <button type="submit" className="w-full bg-green-600 text-white p-3 rounded-lg hover:bg-green-700 font-semibold transition-colors shadow-md">
                    {t('auth.registerSubmit')}
                </button>
                <button type="button" onClick={onSwitchMode} className="w-full bg-transparent text-gray-600 p-3 rounded-lg hover:bg-gray-100 font-semibold transition-colors">
                    {t('auth.switchToLogin')}
                </button>
            </div>
        </form>
    );
};