import { useState } from 'react';
import { useTranslation } from 'react-i18next';

export const LanguageSelector = () => {
    const { i18n } = useTranslation();
    const [isOpen, setIsOpen] = useState(false);

    const languages = [
        { code: 'en', label: 'EN' },
        { code: 'ru', label: 'RU' }
    ];

    const currentLanguage = languages.find(lang => lang.code === i18n.language) || languages[0];

    return (
        <div className="relative flex justify-end mb-4">
            <button
                type="button"
                onClick={() => setIsOpen(!isOpen)}
                className="bg-gray-100 hover:bg-gray-200 text-gray-700 font-bold py-1 px-3 rounded-md text-xs transition-colors border border-gray-300"
            >
                {currentLanguage.label}
            </button>

            {isOpen && (
                <div className="absolute top-8 right-0 bg-white border border-gray-200 rounded-md shadow-lg z-50 py-1 min-w-[60px]">
                    {languages.map((lang) => (
                        <button
                            key={lang.code}
                            className={`block w-full text-left px-4 py-2 text-xs hover:bg-blue-50 transition-colors ${
                                i18n.language === lang.code ? 'text-blue-600 font-bold' : 'text-gray-700'
                            }`}
                            onClick={() => {
                                i18n.changeLanguage(lang.code);
                                setIsOpen(false);
                            }}
                        >
                            {lang.label}
                        </button>
                    ))}
                </div>
            )}
        </div>
    );
};