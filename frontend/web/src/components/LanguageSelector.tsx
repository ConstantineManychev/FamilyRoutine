import { useState, useRef, useEffect } from 'react';
import { useTranslation } from 'react-i18next';

const AVAILABLE_LANGUAGES = [
    { code: 'en', label: 'EN' },
    { code: 'ru', label: 'RU' }
];

export const LanguageSelector = () => {
    const { i18n } = useTranslation();
    const [isOpen, setIsOpen] = useState(false);
    const dropdownRef = useRef<HTMLDivElement>(null);

    const activeLanguage = AVAILABLE_LANGUAGES.find(lang => lang.code === i18n.language) || AVAILABLE_LANGUAGES[0];

    useEffect(() => {
        const handleClickOutside = (event: MouseEvent) => {
            if (dropdownRef.current && !dropdownRef.current.contains(event.target as Node)) {
                setIsOpen(false);
            }
        };

        document.addEventListener('mousedown', handleClickOutside);
        return () => document.removeEventListener('mousedown', handleClickOutside);
    }, []);

    const handleSelectLanguage = (code: string) => {
        i18n.changeLanguage(code);
        setIsOpen(false);
    };

    return (
        <div className="relative" ref={dropdownRef}>
            <button
                type="button"
                onClick={() => setIsOpen(!isOpen)}
                className="bg-white/90 hover:bg-white text-gray-800 font-bold py-1.5 px-3 rounded-md shadow-sm transition-colors border border-gray-300 flex items-center gap-1.5 text-sm"
            >
                {activeLanguage.label}
                <svg className={`w-4 h-4 transition-transform ${isOpen ? 'rotate-180' : ''}`} fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="19 9l-7 7-7-7" />
                </svg>
            </button>

            {isOpen && (
                <div className="absolute top-full right-0 mt-1 bg-white border border-gray-200 rounded-md shadow-xl z-[100] min-w-[70px] max-h-[160px] overflow-y-auto">
                    {AVAILABLE_LANGUAGES.map((language) => (
                        <button
                            key={language.code}
                            type="button"
                            className={`block w-full text-left px-4 py-2 text-sm transition-colors hover:bg-blue-50 ${
                                i18n.language === language.code ? 'text-blue-600 font-bold bg-blue-50/50' : 'text-gray-700'
                            }`}
                            onClick={() => handleSelectLanguage(language.code)}
                        >
                            {language.label}
                        </button>
                    ))}
                </div>
            )}
        </div>
    );
};