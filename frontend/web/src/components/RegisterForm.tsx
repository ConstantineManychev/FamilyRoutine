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
    const [errMsg, setErrMsg] = useState('');

    const handleSubmit = async (e: FormEvent) => {
        e.preventDefault();
        setErrMsg('');

        try {
            await apiClient.post('/api/auth/register', {
                first_name: fName,
                last_name: lName,
                email,
                birth_date: dob,
                password: pwd
            });
            onSwitchMode();
        } catch {
            setErrMsg(t('auth.registerError'));
        }
    };

    return (
        <form onSubmit={handleSubmit} className="flex flex-col gap-6 w-full">
            <h2 className="text-3xl font-bold text-center text-gray-800">
                {t('auth.registerTitle')}
            </h2>

            {errMsg && (
                <div className="bg-red-50 text-red-600 p-3 rounded-lg text-sm text-center">
                    {errMsg}
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